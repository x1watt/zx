// The Dart end of the pipe to native/fuse/zx-mount.c (docs/mount.md): reads
// the requests of the daemon, runs them on a [ZxFs] and writes the answers.
// The frame format is described at the top of zx-mount.c. Requests are
// answered one at a time, in order.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../host/io.dart';
import 'zx_fs.dart';

class FuseOp {
  static const getattr = 1,
      readdir = 2,
      open = 3,
      create = 4,
      read = 5,
      write = 6,
      release = 7,
      unlink = 8,
      rmdir = 9,
      mkdir = 10,
      rename = 11,
      truncate = 12,
      fsync = 13,
      readlink = 14,
      statfs = 15,
      destroy = 16;
}

class _R {
  final Uint8List b;
  int pos = 0;
  _R(this.b);
  ByteData get _d => ByteData.sublistView(b);
  int u8() => b[pos++];
  int u32() {
    final v = _d.getUint32(pos, Endian.little);
    pos += 4;
    return v;
  }

  int u64() {
    final v = _d.getUint64(pos, Endian.little);
    pos += 8;
    return v;
  }

  String str() {
    final n = u32();
    final s = utf8.decode(b.sublist(pos, pos + n), allowMalformed: true);
    pos += n;
    return s;
  }

  Uint8List bytes(int n) {
    final v = Uint8List.sublistView(b, pos, pos + n);
    pos += n;
    return v;
  }
}

class _W {
  final _b = BytesBuilder(copy: false);
  void u8(int v) => _b.addByte(v);
  void u32(int v) =>
      _b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  void u64(int v) =>
      _b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());
  void str(String s) {
    final e = utf8.encode(s);
    u32(e.length);
    _b.add(e);
  }

  void raw(Uint8List d) => _b.add(d);
  Uint8List take() => _b.takeBytes();
}

/// Serves [fs] to the daemon [daemon] until it exits. [log] gets the
/// messages. Returns 0 after a clean unmount, else a non-zero exit code.
Future<int> serveFuse(ZxFs fs, Process daemon, void Function(String) log) async {
  Future<void> send(int status, [Uint8List? payload]) async {
    final body = _W()..u32(status & 0xFFFFFFFF);
    if (payload != null) body.raw(payload);
    final b = body.take();
    final h = ByteData(4)..setUint32(0, b.length, Endian.little);
    daemon.stdin.add(h.buffer.asUint8List());
    daemon.stdin.add(b);
    await daemon.stdin.flush();
  }

  var done = false;
  Future<void> handle(Uint8List frame) async {
    final r = _R(frame);
    final op = r.u8();
    try {
      final out = await _dispatch(fs, op, r);
      await send(0, out);
      if (op == FuseOp.destroy) done = true;
    } on FsError catch (e) {
      await send(-e.errno);
    } catch (e) {
      log('request $op failed: $e');
      await send(-FsError.eio);
    }
  }

  final pending = BytesBuilder(copy: false);
  var have = Uint8List(0);
  final sub = daemon.stdout.listen(null);
  final queue = StreamController<Uint8List>();
  // frames are cut here, handled one by one below
  sub.onData((chunk) {
    pending.add(chunk);
    have = pending.takeBytes();
    var pos = 0;
    while (have.length - pos >= 4) {
      final n = ByteData.sublistView(have, pos).getUint32(0, Endian.little);
      if (have.length - pos - 4 < n) break;
      queue.add(Uint8List.sublistView(have, pos + 4, pos + 4 + n));
      pos += 4 + n;
    }
    pending.add(Uint8List.sublistView(have, pos));
  });
  sub.onDone(queue.close);
  await for (final f in queue.stream) {
    sub.pause();
    await handle(f);
    sub.resume();
  }
  final code = await daemon.exitCode;
  // a clean unmount (destroy handled, changes written) is a success, whatever
  // the daemon's own status says after a signal
  if (done) return 0;
  log('the FUSE daemon ended without a clean unmount');
  return code == 0 ? 1 : code;
}

Future<Uint8List?> _dispatch(ZxFs fs, int op, _R r) async {
  switch (op) {
    case FuseOp.getattr:
      final s = fs.getattr(r.str());
      return (_W()
            ..u8(s.isSymlink ? 3 : (s.isDir ? 2 : 1))
            ..u32(s.mode)
            ..u64(s.size)
            ..u64(s.mtimeSec)
            ..u32(s.nlink))
          .take();
    case FuseOp.readdir:
      final l = fs.readdir(r.str());
      final w = _W()..u32(l.length);
      for (final e in l) {
        w
          ..u8(e.$2 ? 2 : 1)
          ..str(e.$1);
      }
      return w.take();
    case FuseOp.open:
      final p = r.str();
      final flags = r.u32();
      final fh = await fs.open(p, write: flags & 1 != 0, truncate: flags & 2 != 0);
      return (_W()..u64(fh)).take();
    case FuseOp.create:
      final p = r.str();
      final fh = await fs.create(p, mode: r.u32());
      return (_W()..u64(fh)).take();
    case FuseOp.read:
      final fh = r.u64(), off = r.u64(), n = r.u32();
      return await fs.read(fh, off, n);
    case FuseOp.write:
      final fh = r.u64(), off = r.u64(), n = r.u32();
      final w = fs.write(fh, off, Uint8List.fromList(r.bytes(n)));
      return (_W()..u32(w)).take();
    case FuseOp.release:
      fs.release(r.u64());
      return null;
    case FuseOp.unlink:
      await fs.remove(r.str(), dir: false);
      return null;
    case FuseOp.rmdir:
      await fs.remove(r.str(), dir: true);
      return null;
    case FuseOp.mkdir:
      await fs.mkdir(r.str());
      return null;
    case FuseOp.rename:
      final a = r.str();
      await fs.rename(a, r.str());
      return null;
    case FuseOp.truncate:
      final p = r.str();
      await fs.truncate(p, r.u64());
      return null;
    case FuseOp.fsync:
      try {
        await fs.commit();
      } catch (e) {
        throw FsError(FsError.eio, 'commit: $e');
      }
      return null;
    case FuseOp.readlink:
      return (_W()..str(fs.readlink(r.str()))).take();
    case FuseOp.statfs:
      final t = fs.totals;
      return (_W()
            ..u64(t.files)
            ..u64(t.bytes))
          .take();
    case FuseOp.destroy:
      final e = await fs.close();
      if (e != null) throw FsError(FsError.eio, 'commit: $e');
      return null;
  }
  throw FsError(FsError.einval, 'unknown request $op');
}
