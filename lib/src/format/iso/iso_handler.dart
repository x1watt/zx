// The ISO 9660 handler (read only): IInArchive (Open, GetProperty, Extract,
// GetStream) over the reader of iso_in.dart. Images with 2048 byte sectors
// and raw CD images with 2352 byte sectors (mode 1 or mode 2 form 1) are
// read. The item names and properties follow what 7-Zip lists for ISO
// images ("[BOOT]/Boot-NoEmul.img" for El Torito images); 7-Zip's own ISO
// handler (LGPL) was not used.

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import 'disc_streams.dart';
import 'iso_in.dart';
import 'zisofs.dart';

/// Offset of the first volume descriptor ("CD001" at 0x8001).
const int kIsoVdOffset = 0x8000;

/// IsArc for ISO 9660: a primary volume descriptor at sector 16 of a 2048
/// byte sector image, or of a raw 2352 byte sector image.
int isArcIso(Uint8List p, int size) {
  if (size >= kIsoVdOffset + 7) {
    if (IsoReader.hasPvdAt(p, kIsoVdOffset)) return 1;
  } else {
    return 2;
  }
  final off = RawSectorInStream.dataOffsetOf(p, size, 16);
  if (off >= 0) {
    final vd = 16 * RawSectorInStream.rawSectorSize + off;
    if (size >= vd + 7 && IsoReader.hasPvdAt(p, vd)) return 1;
  }
  if (size < 17 * RawSectorInStream.rawSectorSize) return 2;
  return 0;
}

/// The ISO 9660 handler.
class IsoHandler {
  SeekableInStream? _file;
  SeekableInStream? _image; // the 2048 byte sector view
  IsoReader? _r;
  bool _raw = false;

  /// IInArchive::Open. false when the stream is not an ISO 9660 image.
  bool open(SeekableInStream stream) {
    close();
    final head = readAt(stream, 0, kIsoVdOffset + 2048);
    SeekableInStream image = stream;
    var raw = false;
    if (!(head.length >= kIsoVdOffset + 7 &&
        IsoReader.hasPvdAt(head, kIsoVdOffset))) {
      final probe = readAt(stream, 16 * RawSectorInStream.rawSectorSize, 2352);
      final off = RawSectorInStream.dataOffsetOf(probe, probe.length, 0);
      if (off < 0 || !IsoReader.hasPvdAt(probe, off)) return false;
      image = RawSectorInStream(stream, off);
      raw = true;
    }
    final r = IsoReader(image);
    if (!r.open()) return false;
    _file = stream;
    _image = image;
    _r = r;
    _raw = raw;
    return true;
  }

  /// IInArchive::Close.
  void close() {
    _file = null;
    _image = null;
    _r = null;
    _raw = false;
  }

  List<IsoItem> get _items => _r!.items;

  int get numberOfItems => _r?.items.length ?? 0;

  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.cTime,
    Kpid.aTime,
    Kpid.changeTime,
    Kpid.attrib,
    Kpid.posixAttrib,
    Kpid.symLink,
    Kpid.userId,
    Kpid.groupId,
    Kpid.links,
    Kpid.method,
  ];

  static const List<int> archivePropIds = [
    Kpid.volumeName,
    Kpid.fileSystem,
    Kpid.cTime,
    Kpid.mTime,
    Kpid.clusterSize,
    Kpid.creatorApp,
    Kpid.comment,
  ];

  int get errorFlags {
    final r = _r;
    if (r == null) return ErrorFlags.isNotArc;
    var v = 0;
    if (r.headersError) v |= ErrorFlags.headersError;
    if (r.unexpectedEnd) v |= ErrorFlags.unexpectedEnd;
    return v;
  }

  String _fileSystem(IsoReader r) {
    final parts = <String>['ISO9660'];
    if (r.names == IsoNames.joliet) parts.add('Joliet');
    if (r.names == IsoNames.rockRidge) parts.add('RockRidge');
    if (r.hasJoliet && r.names != IsoNames.joliet) parts.add('(Joliet)');
    if (r.hasZisofs) parts.add('zisofs');
    if (r.hasBoot) parts.add('ElTorito');
    if (_raw) parts.add('Raw2352');
    return parts.join(' ');
  }

  String _comment(IsoReader r) {
    final sb = StringBuffer();
    void add(String k, String v) {
      if (v.isNotEmpty) sb.write('$k: $v\n');
    }

    add('SystemId', r.systemId);
    add('VolumeId', r.volumeId);
    add('VolumeSetId', r.volumeSetId);
    add('PublisherId', r.publisherId);
    add('DataPreparerId', r.preparerId);
    add('ApplicationId', r.applicationId);
    if (r.numSessions > 1) add('Sessions', '${r.numSessions}');
    return sb.toString();
  }

  // GetArchiveProperty
  Object? getArchiveProperty(int propId) {
    final r = _r;
    switch (propId) {
      case Kpid.phySize:
        if (r == null) return null;
        final f = _file!;
        if (_raw) return f.length;
        final p = r.phySize;
        return p > f.length ? f.length : p;
      case Kpid.errorFlags:
        return errorFlags;
      case Kpid.volumeName:
        final l = r?.label ?? '';
        return l.isEmpty ? null : l;
      case Kpid.fileSystem:
        return r == null ? null : _fileSystem(r);
      case Kpid.cTime:
        return r?.created;
      case Kpid.mTime:
        return r?.modified;
      case Kpid.clusterSize:
        return r?.blockSize;
      case Kpid.creatorApp:
        final a = r?.applicationId ?? '';
        return a.isEmpty ? null : a;
      case Kpid.comment:
        if (r == null) return null;
        final c = _comment(r);
        return c.isEmpty ? null : c;
    }
    return null;
  }

  static int? posixAttribOf(IsoItem it) {
    final m = it.mode;
    if (m == null) return null;
    var mode = m & 0xFFFF;
    if ((mode & kIfMt) == 0) mode |= it.isDir ? kIfDir : kIfReg;
    return mode;
  }

  // GetProperty
  Object? getProperty(int index, int propId) {
    final r = _r;
    if (r == null || index < 0 || index >= r.items.length) return null;
    final it = r.items[index];
    switch (propId) {
      case Kpid.path:
        return it.path;
      case Kpid.isDir:
        return it.isDir;
      case Kpid.size:
        return it.isDir ? null : it.size;
      case Kpid.packSize:
        if (it.isDir) return null;
        if (it.isSymLink) return 0;
        return it.runs.recorded;
      case Kpid.mTime:
        return it.mTime;
      case Kpid.cTime:
        return it.cTime;
      case Kpid.aTime:
        return it.aTime;
      case Kpid.changeTime:
        return it.changeTime;
      case Kpid.attrib:
        if (!it.hidden) return null;
        var a = FileAttrib.hidden;
        if (it.isDir) a |= FileAttrib.directory;
        final m = posixAttribOf(it);
        if (m != null) a |= FileAttrib.unixExtension | (m << 16);
        return a;
      case Kpid.posixAttrib:
        return posixAttribOf(it);
      case Kpid.symLink:
        final l = it.symlink;
        return l == null || l.isEmpty ? null : l;
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
      case Kpid.links:
        return it.nlink;
      case Kpid.method:
        return it.zfLog2 != 0 ? 'zisofs:${1 << (it.zfLog2 - 10)}k' : null;
    }
    return null;
  }

  /// IInArchiveGetStream::GetStream: random access to the data of a file.
  SeekableInStream? getStream(int index) {
    final r = _r;
    if (r == null || index < 0 || index >= r.items.length) return null;
    final it = r.items[index];
    if (it.isDir || it.isSymLink) return null;
    return _dataStream(it);
  }

  SeekableInStream _dataStream(IsoItem it) {
    final img = _image!;
    if (it.zfLog2 != 0) {
      final raw = RunsInStream(img, it.runs, it.runs.total);
      return ZisofsInStream(raw, it.size, it.zfLog2);
    }
    return RunsInStream(img, it.runs, it.size);
  }

  /// IInArchive::Extract. [indices] null means all items.
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final items = _items;
    final ix = indices ?? [for (var i = 0; i < items.length; i++) i];
    var total = 0;
    for (final i in ix) {
      if (!items[i].isDir) total += items[i].size;
    }
    cb.setTotal(total);
    var completed = 0;
    final buf = Uint8List(1 << 16);
    for (final index in ix) {
      cb.setCompleted(completed);
      final it = items[index];
      var askMode = testMode ? AskMode.test : AskMode.extract;
      final out = cb.getStream(index, askMode);
      if (!testMode && out == null && !it.isDir) askMode = AskMode.skip;
      cb.prepareOperation(askMode);
      if (it.isDir) {
        cb.setOperationResult(OperationResult.ok);
        continue;
      }
      var opRes = OperationResult.ok;
      if (it.isSymLink) {
        final t = Uint8List.fromList(utf8.encode(it.symlink!));
        out?.write(t, 0, t.length);
      } else {
        final src = _dataStream(it);
        var done = 0;
        final size = it.size;
        try {
          while (done < size) {
            var want = size - done;
            if (want > buf.length) want = buf.length;
            final n = src.read(buf, 0, want);
            if (n == 0) break;
            out?.write(buf, 0, n);
            done += n;
            if ((done & 0xFFFFF) < n) cb.setCompleted(completed + done);
          }
          if (done < size) opRes = OperationResult.unexpectedEnd;
        } on SevenZipException catch (e) {
          opRes = e.kind == SevenZipError.unexpectedEnd
              ? OperationResult.unexpectedEnd
              : OperationResult.dataError;
        }
      }
      out?.flush();
      completed += it.size;
      cb.setOperationResult(opRes);
    }
    cb.setCompleted(completed);
  }
}
