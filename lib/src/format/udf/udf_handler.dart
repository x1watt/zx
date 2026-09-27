// The UDF handler (read only): IInArchive (Open, GetProperty, Extract,
// GetStream) over the reader of udf_in.dart. Raw CD images with 2352 byte
// sectors are read through their 2048 byte user data. The properties
// follow what 7-Zip lists for UDF volumes; 7-Zip's own UDF handler (LGPL)
// was not used.

import 'dart:convert';
import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import '../iso/disc_streams.dart';
import 'udf_in.dart';

/// IsArc for UDF: the volume recognition sequence (BEA01, NSR02 or NSR03)
/// at 32 KiB.
int isArcUdf(Uint8List p, int size) {
  final r = UdfReader.isArc(p, size);
  if (r != 0) return r;
  // a raw 2352 byte sector image: the sequence in sectors 16 and on
  final off = RawSectorInStream.dataOffsetOf(p, size, 16);
  if (off < 0) return 0;
  final need = 20 * RawSectorInStream.rawSectorSize;
  if (size < need) return 2;
  final v = Uint8List(2048 * 20);
  for (var i = 0; i < 20; i++) {
    final src = i * RawSectorInStream.rawSectorSize + off;
    v.setRange(i * 2048, i * 2048 + 2048, p, src);
  }
  return UdfReader.isArc(v, v.length) == 1 ? 1 : 0;
}

/// The UDF handler.
class UdfHandler {
  SeekableInStream? _file;
  UdfReader? _r;
  bool _raw = false;

  /// IInArchive::Open. false when the stream is not a UDF volume.
  bool open(SeekableInStream stream) {
    close();
    var r = UdfReader(stream);
    var raw = false;
    if (!r.open()) {
      final probe = readAt(stream, 16 * RawSectorInStream.rawSectorSize, 2352);
      final off = RawSectorInStream.dataOffsetOf(probe, probe.length, 0);
      if (off < 0) return false;
      r = UdfReader(RawSectorInStream(stream, off));
      if (!r.open()) return false;
      raw = true;
    }
    _file = stream;
    _r = r;
    _raw = raw;
    return true;
  }

  void close() {
    _file = null;
    _r = null;
    _raw = false;
  }

  int get numberOfItems => _r?.items.length ?? 0;

  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.packSize,
    Kpid.mTime,
    Kpid.aTime,
    Kpid.cTime,
    Kpid.changeTime,
    Kpid.attrib,
    Kpid.posixAttrib,
    Kpid.symLink,
    Kpid.userId,
    Kpid.groupId,
    Kpid.links,
  ];

  static const List<int> archivePropIds = [
    Kpid.unpackVer,
    Kpid.volumeName,
    Kpid.clusterSize,
    Kpid.sectorSize,
    Kpid.cTime,
    Kpid.mTime,
    Kpid.comment,
  ];

  int get errorFlags {
    final r = _r;
    if (r == null) return ErrorFlags.isNotArc;
    var v = 0;
    if (r.headersError) v |= ErrorFlags.headersError;
    if (r.unexpectedEnd) v |= ErrorFlags.unexpectedEnd;
    if (r.unsupportedFeature) v |= ErrorFlags.unsupportedFeature;
    return v;
  }

  String _comment(UdfReader r) {
    final sb = StringBuffer();
    void add(String k, String v) {
      if (v.isNotEmpty) sb.write('$k: $v\n');
    }

    add('VolumeId', r.volumeId);
    add('VolumeSetId', r.volumeSetId);
    add('LogicalVolumeId', r.logicalVolumeId);
    add('FileSetId', r.fileSetId);
    add('ImplementationId', r.implementationId);
    add('DomainId', r.domainId);
    add('PartitionMaps', r.mapNames.join(' '));
    if (_raw) add('Image', 'Raw2352');
    return sb.toString();
  }

  // GetArchiveProperty
  Object? getArchiveProperty(int propId) {
    final r = _r;
    switch (propId) {
      case Kpid.phySize:
        if (r == null) return null;
        return _raw ? _file!.length : r.phySize;
      case Kpid.errorFlags:
        return errorFlags;
      case Kpid.unpackVer:
        final v = r?.revisionString ?? '';
        return v.isEmpty ? null : v;
      case Kpid.volumeName:
        if (r == null) return null;
        final l = r.logicalVolumeId.isNotEmpty ? r.logicalVolumeId : r.volumeId;
        return l.isEmpty ? null : l;
      case Kpid.clusterSize:
        return r?.blockSize;
      case Kpid.sectorSize:
        return r?.sectorSize;
      case Kpid.cTime:
        return r?.created;
      case Kpid.mTime:
        return r?.modified;
      case Kpid.comment:
        if (r == null) return null;
        final c = _comment(r);
        return c.isEmpty ? null : c;
    }
    return null;
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
        return it.isDir ? null : it.packSize;
      case Kpid.mTime:
        return it.mTime;
      case Kpid.aTime:
        return it.aTime;
      case Kpid.cTime:
        return it.cTime;
      case Kpid.changeTime:
        return it.changeTime;
      case Kpid.attrib:
        if (!it.hidden) return null;
        var a = FileAttrib.hidden;
        if (it.isDir) a |= FileAttrib.directory;
        final m = it.mode;
        if (m != null) a |= FileAttrib.unixExtension | (m << 16);
        return a;
      case Kpid.posixAttrib:
        return it.mode;
      case Kpid.symLink:
        final l = it.symlink;
        return l == null || l.isEmpty ? null : l;
      case Kpid.userId:
        return it.uid;
      case Kpid.groupId:
        return it.gid;
      case Kpid.links:
        return it.nlink;
    }
    return null;
  }

  /// IInArchiveGetStream::GetStream: random access to the data of a file.
  SeekableInStream? getStream(int index) {
    final r = _r;
    if (r == null || index < 0 || index >= r.items.length) return null;
    final it = r.items[index];
    if (it.isDir || it.isSymLink || it.unsupported) return null;
    return _dataStream(it);
  }

  SeekableInStream _dataStream(UdfItem it) {
    final inl = it.inline;
    if (inl != null) {
      return MemoryInStream(Uint8List.sublistView(inl, 0, it.size));
    }
    return RunsInStream(_r!.s, it.runs, it.size);
  }

  /// IInArchive::Extract. [indices] null means all items.
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final items = _r!.items;
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
      } else if (it.unsupported) {
        opRes = OperationResult.unsupportedMethod;
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
