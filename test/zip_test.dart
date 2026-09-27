import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/common/method_props.dart';
import 'package:zx/src/crypto/hmac_sha1.dart';
import 'package:zx/src/crypto/sha1.dart';
import 'package:zx/src/crypto/winzip_aes.dart';
import 'package:zx/src/crypto/zip_crypto.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zip/zip_handler.dart';
import 'package:zx/src/format/zip/zip_header.dart';
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

Uint8List text(int lines) => Uint8List.fromList(
    utf8.encode([for (var i = 0; i < lines; i++) 'line $i\n'].join()));

String hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List ascii(String s) => Uint8List.fromList(utf8.encode(s));

bool _have(String p) => File(p).existsSync();
final bool have7z = _have('/usr/bin/7z');
final bool haveZip = _have('/usr/bin/zip');
final bool haveUnzip = _have('/usr/bin/unzip');
final String? python = ['/usr/bin/python3', '/bin/python3']
    .where(_have)
    .cast<String?>()
    .firstWhere((_) => true, orElse: () => null);
final String _javaBin =
    '${Platform.environment['HOME']}/.sdkman/candidates/java/current/bin';
final bool haveJar = _have('$_javaBin/jar');

class _Collect extends ArchiveExtractCallback implements CryptoGetTextPassword {
  final Map<int, MemoryOutStream> outs = {};
  final Map<int, int> results = {};
  final String? password;
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
  String cryptoGetTextPassword() {
    final p = password;
    if (p == null) throw StateError('no password');
    return p;
  }

  Uint8List data(int i) => outs[i]!.toBytes();
}

/// A non seekable view of bytes (a pipe) with short reads.
class _Pipe implements InStream {
  final Uint8List b;
  int p = 0;
  _Pipe(this.b);
  @override
  int read(Uint8List buf, int off, int len) {
    var n = b.length - p;
    if (n > len) n = len;
    if (n > 700) n = 700;
    buf.setRange(off, off + n, b, p);
    p += n;
    return n;
  }
}

/// A non seekable output.
class _SeqOut implements OutStream {
  final MemoryOutStream m = MemoryOutStream();
  @override
  void write(Uint8List buf, int off, int len) => m.write(buf, off, len);
  @override
  void flush() {}
}

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
  int opResults = 0;
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
  void setOperationResult(int opRes) => opResults++;

  @override
  String? cryptoGetTextPassword2() => password;
}

// 2024-05-01 12:00:00 UTC
final int kTime = unixToFileTime(1714564800);

ZipHandler openBytes(Uint8List b) {
  final h = ZipHandler();
  expect(h.open(MemoryInStream(b)), isTrue);
  return h;
}

/// Writes a new archive of [ups] with the -m [props].
Uint8List _writeZip(List<_Up> ups,
    {List<MapEntry<String, PropVariant>> props = const [],
    String? password,
    bool seekable = true}) {
  final h = ZipHandler();
  h.setProperties(props);
  h.writeOptions.random = Random(1);
  if (seekable) {
    final out = MemoryOutStream();
    h.updateItems(out, ups.length, _UpdateCb(ups, password));
    return Uint8List.fromList(out.toBytes());
  }
  final out = _SeqOut();
  h.updateItems(out, ups.length, _UpdateCb(ups, password));
  return Uint8List.fromList(out.m.toBytes());
}

/// Extracts every item; returns path to data (directories as empty), and
/// checks every result is OK.
Map<String, Uint8List> extractAll(ZipHandler h, [String? password]) {
  final c = _Collect(password);
  h.extract(null, false, c);
  final r = <String, Uint8List>{};
  for (var i = 0; i < h.numberOfItems; i++) {
    expect(c.results[i], OperationResult.ok,
        reason: 'item ${h.getProperty(i, Kpid.path)}');
    if (h.getProperty(i, Kpid.isDir) == true) continue;
    r[h.getProperty(i, Kpid.path) as String] = c.data(i);
  }
  return r;
}

MapEntry<String, PropVariant> prop(String name, String value) =>
    convertCliProperty(name, value);

Directory tmp() => Directory.systemTemp.createTempSync('zx_zip_test');

ProcessResult run(String exe, List<String> args, {String? dir}) =>
    Process.runSync(exe, args, workingDirectory: dir, stdoutEncoding: latin1);

/// The small tree the interop tests archive.
Map<String, Uint8List> sampleFiles() => {
      'a.txt': text(2000),
      'sub/b.bin': gen(30000, 7),
      'sub/deep/c.txt': ascii('hello zip\n' * 300),
      'empty.txt': Uint8List(0),
    };

void writeTree(Directory d, Map<String, Uint8List> files) {
  for (final e in files.entries) {
    final f = File('${d.path}/${e.key}');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(e.value);
  }
}

void main() {
  group('crypto', () {
    test('SHA-1 and HMAC-SHA1', () {
      expect(hex(Sha1.hash(ascii('abc'))),
          'a9993e364706816aba3e25717850c26c9cd0d89d');
      expect(
          hex(Sha1.hash(ascii(
              'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
          '84983e441c3bd26ebaae4aa1f95129e5e54670f1');
      // RFC 2202, test case 2
      expect(
          hex(HmacSha1.mac(
              ascii('Jefe'), ascii('what do ya want for nothing?'))),
          'effcdf6ae5eb2fa2d27416d5f184df9c259a7c79');
    });

    test('PBKDF2-HMAC-SHA1 (RFC 6070)', () {
      expect(hex(pbkdf2HmacSha1(ascii('password'), ascii('salt'), 1, 20)),
          '0c60c80f961f0e71f3a9b524af6012062fe037a6');
      expect(hex(pbkdf2HmacSha1(ascii('password'), ascii('salt'), 4096, 20)),
          '4b007901b765489abead49d926f721d065a429c1');
      expect(
          hex(pbkdf2HmacSha1(ascii('passwordPASSWORDpassword'),
              ascii('saltSALTsaltSALTsaltSALTsaltSALTsalt'), 4096, 25)),
          '3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038');
    });

    test('ZipCrypto and WinZip AES round trips', () {
      final data = gen(5000, 3);
      final out = MemoryOutStream();
      final enc = ZipCryptoEncoder(out, ascii('pw'))
        ..writeHeader(0x5A, Random(2));
      enc.write(data, 0, data.length);
      final dec = ZipCryptoDecoder(MemoryInStream(out.toBytes()), ascii('pw'));
      expect(dec.readHeader(), 0x5A);
      expect(readAll(dec), data);

      for (final strength in [1, 2, 3]) {
        final o = MemoryOutStream();
        final e = WzAesEncoder(o, ascii('secret'), strength)
          ..writeHeader(Random(4));
        e.write(data, 0, 1234);
        e.write(data, 1234, data.length - 1234);
        e.close();
        final packed = o.toBytes();
        expect(packed.length, data.length + wzAesOverhead(strength));
        final d = WzAesDecoder(
            MemoryInStream(packed), ascii('secret'), strength, data.length);
        expect(d.readHeader(), isTrue);
        expect(readAll(d), data);
        final bad = WzAesDecoder(
            MemoryInStream(packed), ascii('wrong'), strength, data.length);
        expect(bad.readHeader(), isFalse);
        // a changed byte fails the authentication code
        final t = Uint8List.fromList(packed);
        t[40] ^= 1;
        final d2 = WzAesDecoder(
            MemoryInStream(t), ascii('secret'), strength, data.length);
        expect(d2.readHeader(), isTrue);
        expect(() => readAll(d2), throwsA(isA<SevenZipException>()));
      }
    });
  });

  group('header', () {
    test('DOS time round trip and rounding', () {
      final d = fileTimeToDosTime(kTime);
      expect(dosTimeToFileTime(d), kTime);
      // odd seconds round up to the next even second
      expect(dosTimeToFileTime(fileTimeToDosTime(kTime + 10000000)),
          kTime + 20000000);
    });

    test('isArcZip', () {
      final z = _writeZip([_Up.add('x', data: ascii('x'))]);
      expect(isArcZip(z, z.length), 1);
      expect(isArcZip(Uint8List.fromList([0x50, 0x4B]), 2), 2);
      expect(isArcZip(ascii('hello world, not a zip file at all'), 34), 0);
    });
  });

  group('write and read', () {
    final files = sampleFiles();
    List<_Up> ups() => [
          _Up.add('sub', isDir: true, mTime: kTime),
          for (final e in files.entries)
            _Up.add(e.key, data: e.value, mTime: kTime, posix: 0x81A4),
          _Up.add('link', symLink: 'a.txt', mTime: kTime, posix: 0xA1FF),
        ];

    for (final m in [
      'Copy', 'Deflate', 'Deflate64', 'BZip2', 'LZMA', 'PPMd', 'xz' //
    ]) {
      test('method $m', () {
        final z = _writeZip(ups(), props: [prop('m', m)]);
        final h = openBytes(z);
        expect(h.numberOfItems, 6);
        final got = extractAll(h);
        for (final e in files.entries) {
          expect(got[e.key], e.value, reason: e.key);
        }
        expect(utf8.decode(got['link']!), 'a.txt');
        final li = [for (var i = 0; i < 6; i++) h.getProperty(i, Kpid.path)]
            .indexOf('link');
        expect(h.getProperty(li, Kpid.posixAttrib), 0xA1FF);
        expect(h.getProperty(0, Kpid.isDir), isTrue);
        expect(h.getProperty(1, Kpid.mTime), kTime);
        final methods = {
          for (var i = 0; i < 6; i++) h.getProperty(i, Kpid.method) as String
        };
        if (m != 'Copy') {
          expect(methods.any((s) => s.startsWith(m == 'LZMA' ? 'LZMA:eos' : m)),
              isTrue,
              reason: '$methods');
        }
        _checkTools(z, null, m);
      });
    }

    for (final em in ['ZipCrypto', 'AES128', 'AES192', 'AES256']) {
      test('encryption $em', () {
        final z = _writeZip(ups(),
            props: [prop('em', em), prop('m', 'Deflate')], password: 'pw');
        final h = openBytes(z);
        final got = extractAll(h, 'pw');
        for (final e in files.entries) {
          expect(got[e.key], e.value, reason: e.key);
        }
        expect(h.getProperty(1, Kpid.encrypted), isTrue);
        expect(
            h.getProperty(1, Kpid.method),
            em == 'ZipCrypto'
                ? 'ZipCrypto Deflate'
                : 'AES-${em.substring(3)} Deflate');
        // a wrong password
        final c = _Collect('nope');
        h.extract([1], false, c);
        expect(
            c.results[1],
            anyOf(OperationResult.wrongPassword, OperationResult.dataError,
                OperationResult.crcError));
        _checkTools(z, 'pw', em);
      });
    }

    test('level 0 stores, incompressible data is stored', () {
      final z = _writeZip(ups(), props: [prop('x', '0')]);
      final h = openBytes(z);
      for (var i = 0; i < h.numberOfItems; i++) {
        expect(h.getProperty(i, Kpid.method), 'Store');
      }
      final z2 = _writeZip([_Up.add('r', data: gen(10000, 1))]);
      final h2 = openBytes(z2);
      expect(h2.getProperty(0, Kpid.method), 'Store');
      expect(h2.getProperty(0, Kpid.packSize), 10000);
    });

    test('time extras, UTF-8 names, -mcu', () {
      final z = _writeZip([
        _Up.add('\u00FCn\u00EF/\u00E7.txt', data: ascii('x'), mTime: kTime),
        _Up.add('plain.txt', data: ascii('y'), mTime: kTime),
      ], props: [
        prop('tc', 'on'),
        prop('ta', 'on')
      ]);
      final h = openBytes(z);
      expect(h.getProperty(0, Kpid.path), '\u00FCn\u00EF/\u00E7.txt');
      expect(h.getProperty(0, Kpid.characts), 'NTFS : UTF8');
      expect(h.getProperty(1, Kpid.characts), 'NTFS');
      expect(h.getProperty(0, Kpid.mTime), kTime);
      final z2 = _writeZip([_Up.add('plain.txt', data: ascii('y'))],
          props: [prop('tm', 'off')]);
      expect(openBytes(z2).getProperty(0, Kpid.characts), isNull);
    });

    test('invalid switches', () {
      final h = ZipHandler();
      expect(() => h.setProperties([prop('m', 'Nope')]),
          throwsA(isA<InvalidArgException>()));
      expect(() => h.setProperties([prop('em', 'Blowfish')]),
          throwsA(isA<InvalidArgException>()));
    });

    test('streamed output (data descriptors), read back as a stream', () {
      for (final extra in [
        <MapEntry<String, PropVariant>>[],
        [prop('x', '0')],
        [prop('m', 'LZMA')],
        [prop('m', 'BZip2')],
        [prop('em', 'AES256')],
        [prop('em', 'ZipCrypto'), prop('x', '0')],
      ]) {
        final pw = extra.any((e) => e.key == 'em') ? 'pw' : null;
        final z = _writeZip(ups(), props: extra, password: pw, seekable: false);
        // random access
        final got = extractAll(openBytes(z), pw);
        expect(got['sub/b.bin'], files['sub/b.bin']);
        // as a stream
        final h = ZipHandler();
        expect(h.openSeq(_Pipe(z)), isTrue);
        final c = _Collect(pw);
        h.extract(null, false, c);
        expect(h.numberOfItems, 6);
        for (var i = 0; i < 6; i++) {
          expect(c.results[i], OperationResult.ok, reason: '$extra $i');
          final p = h.getProperty(i, Kpid.path);
          if (files.containsKey(p)) expect(c.data(i), files[p]);
        }
        final kind = extra.any((e) => e.value.stringValue == 'LZMA')
            ? 'LZMA'
            : extra.any((e) => e.value.stringValue == 'BZip2')
                ? 'BZip2'
                : extra.any((e) => e.value.stringValue == 'AES256')
                    ? 'AES256'
                    : 'stream';
        _checkTools(z, pw, kind);
      }
    });

    test('update: keep, rename, delete, add', () {
      final z = _writeZip(ups(), props: [prop('m', 'Deflate')]);
      final h = openBytes(z);
      final names = [for (var i = 0; i < 6; i++) h.getProperty(i, Kpid.path)];
      final ia = names.indexOf('a.txt');
      final ib = names.indexOf('sub/b.bin');
      final ic = names.indexOf('sub/deep/c.txt');
      final out = MemoryOutStream();
      final nd = gen(777, 9);
      h.updateItems(
          out,
          4,
          _UpdateCb([
            _Up.keep(ia),
            _Up.keep(ib, 'renamed.bin'),
            _Up.keep(ic),
            _Up.add('new.bin', data: nd, mTime: kTime),
          ]));
      final z2 = Uint8List.fromList(out.toBytes());
      final got = extractAll(openBytes(z2));
      expect(got.keys.toList(),
          ['a.txt', 'renamed.bin', 'sub/deep/c.txt', 'new.bin']);
      expect(got['renamed.bin'], files['sub/b.bin']);
      expect(got['new.bin'], nd);
      _checkTools(z2, null, 'update');
    });

    test('update keeps encrypted items', () {
      final z =
          _writeZip(ups(), props: [prop('em', 'ZipCrypto')], password: 'pw');
      final h = openBytes(z);
      final out = MemoryOutStream();
      h.updateItems(
          out, 2, _UpdateCb([_Up.keep(1, 'x/renamed'), _Up.keep(2)], 'pw'));
      final got =
          extractAll(openBytes(Uint8List.fromList(out.toBytes())), 'pw');
      expect(got.length, 2);
    });

    test('Zip64 end records with 65536 items', () {
      final many = [
        for (var i = 0; i < 65536; i++) _Up.add('f$i', data: Uint8List(0))
      ];
      final z = _writeZip(many, props: [prop('tm', 'off')]);
      final h = openBytes(z);
      expect(h.numberOfItems, 65536);
      expect(h.getArchiveProperty(Kpid.bit64), isTrue);
      expect(h.getProperty(65535, Kpid.path), 'f65535');
      _checkTools(z, null, 'zip64', jar: false);
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('read', () {
    test('truncated archive: local headers without central directory', () {
      final z = _writeZip([
        _Up.add('a', data: text(100)),
        _Up.add('b', data: text(200)),
      ]);
      // cut the central directory
      final h = ZipHandler();
      final cut = Uint8List.sublistView(z, 0, z.length - 60);
      expect(h.open(MemoryInStream(cut)), isTrue);
      expect(h.numberOfItems, 2);
      expect(h.errorFlags & ErrorFlags.unexpectedEnd, isNot(0));
      final c = _Collect();
      h.extract(null, true, c);
      expect(c.results[0], OperationResult.ok);
      expect(c.results[1], OperationResult.ok);
    });

    test('data in front (self extracting stub) and a comment', () {
      final z = _writeZip([_Up.add('a', data: text(10))]);
      final withStub = Uint8List.fromList([...gen(1000, 5), ...z]);
      final h = openBytes(withStub);
      expect(h.getArchiveProperty(Kpid.offset), 1000);
      expect(extractAll(h)['a'], text(10));
      expect(h.open(MemoryInStream(ascii('PK\x03\x04 not really'))), isTrue);
    });

    test('CRC error is reported', () {
      final data = text(300);
      final z = _writeZip([_Up.add('a', data: data)], props: [prop('x', '0')]);
      final t = Uint8List.fromList(z);
      t[30 + 1 + 5] ^= 0xFF; // a byte of the stored data
      final h = openBytes(t);
      final c = _Collect();
      h.extract(null, true, c);
      expect(c.results[0], OperationResult.crcError);
    });

    test('legacy methods (shrink, reduce, implode fixtures)', () {
      final dir = Directory('test/data/zip_legacy');
      if (!dir.existsSync()) return;
      var n = 0;
      for (final f in dir.listSync().whereType<File>()) {
        if (!f.path.endsWith('.zip')) continue;
        final h = ZipHandler();
        expect(h.open(FileInStream.open(f.path)), isTrue);
        final c = _Collect();
        h.extract(null, true, c);
        for (var i = 0; i < h.numberOfItems; i++) {
          expect(c.results[i], OperationResult.ok, reason: f.path);
        }
        n++;
      }
      expect(n, greaterThan(0));
    });

    test('libarchive fixtures', () {
      const base = 'ref/libarchive/libarchive/test';
      if (!Directory(base).existsSync()) return;
      final cases = {
        'test_read_format_zip_winzip_aes128.zip.uu': 'password',
        'test_read_format_zip_winzip_aes256.zip.uu': 'password',
        'test_read_format_zip_traditional_encryption_data.zip.uu': '12345678',
        'test_read_format_zip_ppmd8.zipx.uu': null,
        'test_read_format_zip_ppmd8_multi.zipx.uu': null,
        'test_read_format_zip_lzma.zipx.uu': null,
        'test_read_format_zip_lzma_multi.zipx.uu': null,
        'test_read_format_zip_xz_multi.zipx.uu': null,
        'test_read_format_zip_bzip2.zipx.uu': null,
        'test_read_format_zip_bzip2_multi.zipx.uu': null,
        'test_read_format_zip_zip64a.zip.uu': null,
        'test_read_format_zip_zip64b.zip.uu': null,
        'test_read_format_zip_sfx.uu': null,
        'test_read_format_zip_7075_utf8_paths.zip.uu': null,
        'test_read_format_zip_length_at_end.zip.uu': null,
        'test_read_format_zip_ux.zip.uu': null,
        'test_read_format_zip_jar.jar.uu': null,
        'test_read_format_zip_winzip_aes256_stored.zip.uu': 'password',
      };
      for (final e in cases.entries) {
        final f = File('$base/${e.key}');
        if (!f.existsSync()) continue;
        final data = _uudecode(f.readAsStringSync());
        final h = ZipHandler();
        expect(h.open(MemoryInStream(data)), isTrue, reason: e.key);
        final c = _Collect(e.value);
        h.extract(null, true, c);
        for (var i = 0; i < h.numberOfItems; i++) {
          expect(c.results[i], OperationResult.ok,
              reason: '${e.key} ${h.getProperty(i, Kpid.path)}');
        }
        // the same as a stream when there is no data in front
        if (!e.key.contains('sfx')) {
          final s = ZipHandler();
          expect(s.openSeq(_Pipe(data)), isTrue);
          final c2 = _Collect(e.value);
          s.extract(null, true, c2);
          for (var i = 0; i < h.numberOfItems; i++) {
            expect(c2.results[i], OperationResult.ok,
                reason: 'seq ${e.key} $i');
          }
        }
      }
    });
  });

  group('interop', () {
    late Directory d;
    final files = sampleFiles();
    setUp(() {
      d = tmp();
      writeTree(Directory('${d.path}/src'), files);
      Link('${d.path}/src/lnk').createSync('a.txt');
    });
    tearDown(() => d.deleteSync(recursive: true));

    void checkArchive(String path, {String? password, bool links = false}) {
      final h = ZipHandler();
      final s = FileInStream.open(path);
      try {
        expect(h.open(s), isTrue, reason: path);
        final got = extractAll(h, password);
        for (final e in files.entries) {
          expect(got[e.key], e.value, reason: '$path ${e.key}');
        }
        if (links) {
          expect(utf8.decode(got['lnk']!), 'a.txt');
          final i = [
            for (var k = 0; k < h.numberOfItems; k++)
              h.getProperty(k, Kpid.path)
          ].indexOf('lnk');
          expect((h.getProperty(i, Kpid.posixAttrib) as int) & 0xF000, 0xA000);
        }
      } finally {
        s.close();
      }
    }

    test('archives made by zip', () {
      if (!haveZip) return;
      final src = '${d.path}/src';
      for (final args in [
        ['-0'],
        ['-1'],
        ['-9'],
        ['-y'],
        ['-fz'],
        ['-e', '-P', 'pw'],
      ]) {
        final out = '${d.path}/z${args.join()}.zip';
        final r = run('zip', ['-qr', ...args, out, '.'], dir: src);
        expect(r.exitCode, 0, reason: '${r.stderr}');
        checkArchive(out,
            password: args.contains('-e') ? 'pw' : null,
            links: args.contains('-y'));
        // streamed with data descriptors
        final p = Process.runSync('bash',
            ['-o', 'pipefail', '-c', 'zip -qr ${args.join(' ')} - . | cat'],
            workingDirectory: src, stdoutEncoding: null);
        // zip can not stream some options (links)
        if (p.exitCode != 0) continue;
        final z = Uint8List.fromList(p.stdout as List<int>);
        final h = ZipHandler();
        expect(h.openSeq(_Pipe(z)), isTrue);
        final c = _Collect(args.contains('-e') ? 'pw' : null);
        h.extract(null, true, c);
        expect(c.results.values.every((v) => v == OperationResult.ok), isTrue,
            reason: 'stream $args ${c.results}');
      }
    });

    test('archives made by 7z', () {
      if (!have7z) return;
      final src = '${d.path}/src';
      for (final args in [
        ['-mm=Copy'],
        ['-mm=Deflate'],
        ['-mm=Deflate64'],
        ['-mm=BZip2'],
        ['-mm=LZMA'],
        ['-mm=PPMd'],
        ['-mm=xz'],
        ['-mem=AES256', '-ppw'],
        ['-mem=AES128', '-ppw', '-mm=LZMA'],
        ['-mem=ZipCrypto', '-ppw'],
      ]) {
        final out = '${d.path}/7${args.join()}.zip';
        final r = run('7z', ['a', '-tzip', ...args, out, '.'], dir: src);
        expect(r.exitCode, 0, reason: '${r.stdout}');
        checkArchive(out, password: args.contains('-ppw') ? 'pw' : null);
      }
    });

    test('archives made by jar', () {
      if (!haveJar) return;
      final out = '${d.path}/j.jar';
      final r = run('$_javaBin/jar', ['cf', out, '.'], dir: '${d.path}/src');
      expect(r.exitCode, 0, reason: '${r.stderr}');
      checkArchive(out);
    });
  });
}

// runs the system tools on a written archive
void _checkTools(Uint8List z, String? pw, String what, {bool jar = true}) {
  final aes = what.startsWith('AES') || what.contains('AES');
  final d = tmp();
  try {
    final p = '${d.path}/t.zip';
    File(p).writeAsBytesSync(z);
    final m = what.split(' ').first;
    final unzipOk =
        !aes && !['LZMA', 'PPMd', 'xz'].contains(m) && !what.contains('LZMA');
    if (haveUnzip && unzipOk) {
      final r = run('unzip', [
        '-tqq',
        if (pw != null) ...['-P', pw],
        p
      ]);
      expect(r.exitCode, 0, reason: 'unzip $what: ${r.stdout}${r.stderr}');
    }
    // Python's zipfile has no Deflate64
    if (python != null &&
        pw == null &&
        !['PPMd', 'xz', 'Deflate64'].contains(m)) {
      final r = run(python!, ['-m', 'zipfile', '-t', p]);
      expect(r.exitCode, 0, reason: 'python $what: ${r.stdout}${r.stderr}');
    }
    if (have7z) {
      final r = run('7z', ['t', '-p${pw ?? 'x'}', p]);
      expect(r.stdout.toString(), contains('Everything is Ok'),
          reason: '7z $what: ${r.stdout}');
    }
    if (haveJar &&
        jar &&
        pw == null &&
        ['Copy', 'Deflate', 'update', 'stream'].contains(m)) {
      final r = run('$_javaBin/jar', ['tf', p]);
      expect(r.exitCode, 0, reason: 'jar $what: ${r.stderr}');
    }
  } finally {
    d.deleteSync(recursive: true);
  }
}

Uint8List _uudecode(String s) {
  final out = BytesBuilder();
  var started = false;
  for (final line in const LineSplitter().convert(s)) {
    if (!started) {
      if (line.startsWith('begin')) started = true;
      continue;
    }
    if (line == 'end') break;
    if (line.isEmpty) continue;
    final n = (line.codeUnitAt(0) - 32) & 63;
    if (n == 0) continue;
    final bytes = <int>[];
    for (var i = 1; i + 3 < line.length + 3 && bytes.length < n; i += 4) {
      int c(int k) =>
          i + k < line.length ? (line.codeUnitAt(i + k) - 32) & 63 : 0;
      final v = (c(0) << 18) | (c(1) << 12) | (c(2) << 6) | c(3);
      bytes.add((v >> 16) & 0xFF);
      bytes.add((v >> 8) & 0xFF);
      bytes.add(v & 0xFF);
    }
    out.add(bytes.sublist(0, n));
  }
  return out.takeBytes();
}
