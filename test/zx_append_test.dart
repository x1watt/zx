// Tests of the file side of .zx updates: an append in place while the
// archive is open for reading, the fallback when the archive can not be
// opened for appending (a program holds it, as Windows sharing rules do):
// written again and renamed, with retries, simulated here; and the
// "until full" destination folders of volumes (-mvdir=DIR:full) when no
// tool gives the free space: the space is reserved as the volume is
// written, a full disk simulated.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zx/src/format/archive_types.dart';
import 'package:zx/src/format/zx/zx_format.dart';
import 'package:zx/src/format/zx/zx_handler.dart';
import 'package:zx/src/format/zx/zx_writer.dart';
import 'package:zx/src/io/streams.dart';

import 'zx_test_util.dart';

/// An update callback: (0, path, data) is a new file, (-1, path, null) a
/// kept item of [h] by path.
class _Items extends ArchiveUpdateCallback {
  final List<(int, String, Uint8List?)> items;
  final ZxHandler h;
  _Items(this.items, this.h);

  int _oldIndex(String p) {
    final r = h.reader;
    if (r == null) return -1;
    return r.lastIndex.entries.indexWhere((e) => e.path == p);
  }

  @override
  UpdateItemInfo getUpdateItemInfo(int index) {
    final (k, p, _) = items[index];
    return k == -1
        ? UpdateItemInfo(false, false, _oldIndex(p))
        : const UpdateItemInfo(true, true, -1);
  }

  @override
  Object? getProperty(int index, int propId) {
    final (_, p, d) = items[index];
    return switch (propId) {
      Kpid.path => p,
      Kpid.size => d?.length,
      Kpid.isDir => false,
      _ => null,
    };
  }

  @override
  InStream? getStream(int index) => MemoryInStream(items[index].$3!);
}

ZxHandler _handler() {
  final h = ZxHandler();
  h.options.write
    ..threads = 1
    ..blockSize = 64 << 10
    ..archiveId = Uint8List(16)
    ..time = 1790000000000000000;
  return h;
}

FileSystemException _locked(String p) => FileSystemException(
    'Cannot open file',
    p,
    const OSError(
        'The process cannot access the file because it is being '
        'used by another process',
        32));

void main() {
  final a = textBytes(40000, 1), b = lcgBytes(30000, 2);
  final n = textBytes(12000, 3);
  late Directory tmp;
  final open0 = zxOpenForAppend, replace0 = zxReplaceFile;
  final tries0 = zxReplaceTries, wait0 = zxReplaceWait;
  final tool0 = zxFreeSpaceTool, prealloc0 = zxPreallocWrite;
  setUp(() => tmp = Directory.systemTemp.createTempSync('zx_append_'));
  tearDown(() {
    zxOpenForAppend = open0;
    zxReplaceFile = replace0;
    zxReplaceTries = tries0;
    zxReplaceWait = wait0;
    zxFreeSpaceTool = tool0;
    zxPreallocWrite = prealloc0;
    tmp.deleteSync(recursive: true);
  });

  // a new archive of a and b at [path]
  void create(String path) {
    final h = _handler();
    h.updateFile(path, 2, _Items([(0, 'a', a), (0, 'b', b)], h));
  }

  // appends n to the archive at [path] (a kept, b deleted)
  ZxUpdateFileResult update(String path,
      {void Function(FileInStream s)? release}) {
    final s = FileInStream.open(path);
    final h = _handler();
    expect(h.open(s, path: path), true);
    try {
      return h.updateFile(path, 2, _Items([(-1, 'a', null), (0, 'n', n)], h),
          releaseInput: () => (release ?? (x) => x.close())(s));
    } finally {
      h.close();
      s.close();
    }
  }

  Map<String, Uint8List?> read(String path, {String? version}) =>
      extractAll(openMem(Uint8List.fromList(File(path).readAsBytesSync()),
          version: version));

  group('append in place', () {
    test('while the archive is open for reading', () {
      final path = '${tmp.path}/x.zx';
      create(path);
      final before = File(path).readAsBytesSync();
      // a reader keeps the file open during the append
      final rs = FileInStream.open(path);
      final reader = ZxHandler()..open(rs, path: path);
      final res = update(path);
      expect(res.files, isEmpty);
      expect(res.warnings, isEmpty);
      // the reader still sees the state it opened
      expect(extractAll(reader), {'a': a, 'b': b});
      reader.close();
      rs.close();
      final after = File(path).readAsBytesSync();
      expect(after.sublist(0, before.length), before);
      expect(read(path), {'a': a, 'n': n});
      expect(read(path, version: '1'), {'a': a, 'b': b});
    });

    test('a locked archive is written again and renamed', () {
      final path = '${tmp.path}/x.zx';
      final same = '${tmp.path}/y.zx';
      create(path);
      File(path).copySync(same);
      update(same);
      var released = false;
      var opened = 0;
      zxOpenForAppend = (p) {
        opened++;
        throw _locked(p);
      };
      final res = update(path, release: (s) {
        released = true;
        s.close();
      });
      expect(opened, 1);
      expect(released, true);
      expect(res.warnings.single, contains('written again'));
      expect(File('$path.zx-part').existsSync(), false);
      // the same bytes as the append in place
      expect(File(path).readAsBytesSync(), File(same).readAsBytesSync());
      expect(read(path), {'a': a, 'n': n});
    });

    test('the rename is tried again; a lasting lock changes nothing', () {
      final path = '${tmp.path}/x.zx';
      create(path);
      final before = File(path).readAsBytesSync();
      zxOpenForAppend = (p) => throw _locked(p);
      zxReplaceWait = const Duration(milliseconds: 1);
      var tries = 0;
      zxReplaceFile = (f, t) {
        if (++tries < 3) throw _locked(t);
        File(f).renameSync(t);
      };
      final res = update(path);
      expect(tries, 3);
      expect(res.result.generation, 2);
      expect(read(path), {'a': a, 'n': n});
      // always locked: an error, the archive as it was, no part file
      final kept = File(path).readAsBytesSync();
      zxReplaceTries = 4;
      tries = 0;
      zxReplaceFile = (f, t) {
        tries++;
        throw _locked(t);
      };
      expect(
          () => update(path),
          throwsA(isA<SevenZipException>()
              .having((e) => e.message, 'message', contains('locked'))));
      expect(tries, 4);
      expect(File(path).readAsBytesSync(), kept);
      expect(File('$path.zx-part').existsSync(), false);
      expect(before.length, lessThan(kept.length));
    });

    test('a failure while writing the copy leaves the archive as it was', () {
      final path = '${tmp.path}/x.zx';
      create(path);
      final before = File(path).readAsBytesSync();
      zxOpenForAppend = (p) => throw _locked(p);
      final s = FileInStream.open(path);
      final h = _handler()..open(s, path: path);
      final bad = _Items([(0, 'a/../../x', a)], h);
      expect(() => h.updateFile(path, 1, bad, releaseInput: s.close),
          throwsA(anything));
      h.close();
      s.close();
      expect(File(path).readAsBytesSync(), before);
      expect(File('$path.zx-part').existsSync(), false);
    });
  });

  group('volumes until the disk is full', () {
    test('the output of df', () {
      expect(
          zxParseDfOutput('Filesystem     1024-blocks      Used Available '
              'Capacity Mounted on\n/dev/sda1   100000 50000 42 55% /\n'),
          42 * 1024);
      expect(zxParseDfOutput(''), isNull);
      expect(zxParseDfOutput('header only\n'), isNull);
      expect(zxParseDfOutput('h\na b c x\n'), isNull);
    });

    // writes r1, r2, t into volumes of [size] in [dirs]
    (ZxUpdateFileResult, Map<String, Uint8List>) write(
        List<ZxVolumeDir> dirs, int size) {
      final files = {
        'r1': lcgBytes(150000, 1),
        'r2': lcgBytes(150000, 2),
        't': textBytes(30000, 3),
      };
      final h = ZxHandler();
      h.options.write
        ..threads = 1
        ..blockSize = 64 << 10
        ..volumeDirs = dirs;
      final res = h.updateFile('${tmp.path}/x.zx', files.length,
          _Items([for (final e in files.entries) (0, e.key, e.value)], h),
          volumeSizes: [size]);
      return (res, files);
    }

    Map<String, Uint8List?> readSet(String first, List<String> dirs) {
      final s = FileInStream.open(first);
      try {
        final h = ZxHandler();
        h.options.searchDirs.addAll(dirs);
        expect(h.open(s, path: first), true);
        return extractAll(h);
      } finally {
        s.close();
      }
    }

    int used(Directory d) =>
        d.listSync().fold(0, (s, e) => s + (e as File).lengthSync());

    test('no tool: the space is reserved as the volume is written', () {
      zxFreeSpaceTool = (d) => null;
      var reserved = 0;
      zxPreallocWrite = (f, buf, len) {
        reserved += len;
        f.writeFromSync(buf, 0, len);
      };
      final d1 = Directory('${tmp.path}/d1')..createSync();
      final (res, files) =
          write([ZxVolumeDir(d1.path, untilFull: true)], 100000);
      expect(reserved, greaterThan(0));
      expect(readSet(res.files.first, [d1.path]), files);
      // no reserved zeros are left: each volume ends with its trailer or
      // its Footer
      for (final p in res.files) {
        final bytes = File(p).readAsBytesSync();
        expect(bytes.length, lessThanOrEqualTo(100000 + 4096));
        final tail = bytes.sublist(bytes.length - 32);
        final ok = ZxVolumeTrailer.tryParse(tail, 0) != null ||
            ZxFooter.tryParse(tail, 0) != null;
        expect(ok, true, reason: p);
      }
    });

    test('no tool, a full disk: the next folder takes the rest', () {
      zxFreeSpaceTool = (d) => null;
      final d1 = Directory('${tmp.path}/d1')..createSync();
      final d2 = Directory('${tmp.path}/d2')..createSync();
      // d1 holds 130000 bytes
      const cap = 130000;
      zxPreallocWrite = (f, buf, len) {
        final dir = File(f.path).parent.path;
        if (dir == d1.path) {
          var others = 0;
          for (final e in d1.listSync()) {
            if (e.path != f.path) others += (e as File).lengthSync();
          }
          final pos = f.positionSync();
          if (others + pos + len > cap) {
            // a short write, then the error
            final room = cap - others - pos;
            if (room > 0) f.writeFromSync(buf, 0, room);
            throw FileSystemException('Write failed', f.path,
                const OSError('No space left on device', 28));
          }
        }
        f.writeFromSync(buf, 0, len);
      };
      final (res, files) = write([
        ZxVolumeDir(d1.path, untilFull: true),
        ZxVolumeDir(d2.path, untilFull: true),
      ], 100000);
      expect(used(d1), lessThanOrEqualTo(cap));
      expect(d1.listSync().length, 2); // 100000, then what is left
      expect(d2.listSync(), isNotEmpty);
      expect(readSet(res.files.first, [d1.path, d2.path]), files);
      for (final p in res.files) {
        final bytes = File(p).readAsBytesSync();
        final tail = bytes.sublist(bytes.length - 32);
        expect(
            ZxVolumeTrailer.tryParse(tail, 0) != null ||
                ZxFooter.tryParse(tail, 0) != null,
            true);
      }
    });

    test('a tool: its free space limits the folder', () {
      final d1 = Directory('${tmp.path}/d1')..createSync();
      final d2 = Directory('${tmp.path}/d2')..createSync();
      zxFreeSpaceTool =
          (d) => d == d1.path ? (1 << 20) + 90000 - used(d1) : null;
      var reservedIn1 = 0;
      zxPreallocWrite = (f, buf, len) {
        if (File(f.path).parent.path == d1.path) reservedIn1 += len;
        f.writeFromSync(buf, 0, len);
      };
      final (res, files) = write([
        ZxVolumeDir(d1.path, untilFull: true),
        ZxVolumeDir(d2.path, untilFull: true),
      ], 60000);
      expect(reservedIn1, 0);
      expect(readSet(res.files.first, [d1.path, d2.path]), files);
      expect(d1.listSync(), isNotEmpty);
      expect(d2.listSync(), isNotEmpty);
    });
  });
}
