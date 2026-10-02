// Nested archives (a zx extension, not in 7-Zip): an item of an archive
// that is itself an archive or an image (a firmware section holding a UBI
// image, a partition of a disk image, an ISO inside a tar) is opened as
// the next level through the handler's IInArchiveGetStream, or, when the
// handler has no random access to its items, from a temporary file.
//
// [FlatArc] is an IInArchive over one virtual read-only tree: every item
// that opens as an archive becomes a folder holding the tree of its inner
// archive. It is what `-snest` of the command line tool and
// `ZxArchive.open(flatten: true)` list, test and extract.
//
// Which items are tried:
// - every file item of a container format (ArcInfoEx.isContainer: pak,
//   uImage, UBI, MBR, GPT), and of a compressor opened from one, with the
//   full detection of ArchiveLink (signatures, extensions, IsArc);
// - any other file item whose first bytes match the signature of a
//   registered format (the same signatures and IsArc checks as the
//   detection of OpenArchive.cpp), then opened with the full detection.
//   An item that opens only as a compressor or a device tree (a `.gz` or a
//   `.dtb` in a file system) stays a file: it is data, not a folder.
//
// A nested archive with a single item that opens as an archive too shows
// that archive directly (a UBI image with one volume shows the files of
// the UBIFS volume). The depth is limited and an archive that has the
// format and the size of one of its parents is not opened again (a
// cycle).

import '../host/io.dart';
import 'dart:typed_data';

import '../format/archive_types.dart';
import '../io/streams.dart';
import 'arc_compound.dart' show isCompoundOuterFormat;
import 'arc_handlers.dart';
import 'common.dart';
import 'load_codecs.dart';
import 'open_archive.dart';
import 'platform.dart';
import 'wildcard.dart' show extractFileNameFromPath;

/// The default depth of `-snest` and `ZxArchive.open(flatten: true)`.
const int kDefaultNestDepth = 4;

/// How a nested archive of a [FlatArc] was reached: item [item] of the
/// node [parent] (node 0 is the archive itself, with [parent] -1), opened
/// from [tempFile] when the parent could not give a stream of the item.
class NestNodeSpec {
  final int parent;
  final int item;
  final String? tempFile;
  const NestNodeSpec(this.parent, this.item, [this.tempFile]);
}

/// Formats whose items are data, not files of a tree: an item that opens
/// only as one of them stays a file, unless it comes from a container.
bool isNestLeafFormat(ArcInfoEx ai) =>
    isCompoundOuterFormat(ai) ||
    const {'fdt', 'zstd', 'lz4', 'z'}.contains(ai.name.toLowerCase());

/// The size of the start of an item read to look for signatures (the tar
/// magic is at offset 257).
const int _kHeadSize = 512;

/// Signatures further in (ISO 9660 and UDF at 32 KiB) are read as a small
/// window at their offset.
const int _kFarWindow = 16;

/// The formats of [codecs] that [sniffArchiveHead] checks, with the
/// offsets of the far signatures.
class NestSniffer {
  final Codecs codecs;
  final List<int> _formats = [];
  final Set<int> _farOffsets = {};

  NestSniffer(this.codecs) {
    for (var i = 0; i < codecs.formats.length; i++) {
      final ai = codecs.formats[i];
      if (ai.signatures.isEmpty || ai.isSplit || ai.flagsHashHandler) continue;
      if (ai.flagsByExtOnlyOpen) continue;
      _formats.add(i);
      if (ai.signatureOffset + ai.signatures.first.length > _kHeadSize) {
        _farOffsets.add(ai.signatureOffset);
      }
    }
  }

  /// True when the start of [s] matches the signature of a registered
  /// format (with its IsArc check when it has one).
  bool matches(SeekableInStream s) => formatOf(s) >= 0;

  /// The index in [Codecs.formats] of the first format whose signature
  /// (and IsArc check) matches the start of [s], or -1.
  int formatOf(SeekableInStream s) {
    final len = s.length;
    if (len <= 0) return -1;
    final head = Uint8List(len < _kHeadSize ? len : _kHeadSize);
    s.position = 0;
    final n = readFully(s, head, 0, head.length);
    final h = _matchHead(head, n);
    if (h >= 0) return h;
    for (final off in _farOffsets) {
      if (len < off + _kFarWindow) continue;
      final w = Uint8List(_kFarWindow);
      s.position = off;
      final m = readFully(s, w, 0, w.length);
      final f = _matchFar(w, m, off);
      if (f >= 0) return f;
    }
    return -1;
  }

  int _matchHead(Uint8List head, int n) {
    for (final fi in _formats) {
      final ai = codecs.formats[fi];
      for (final sig in ai.signatures) {
        final end = ai.signatureOffset + sig.length;
        if (end > _kHeadSize || end > n) continue;
        if (!_eq(sig, head, ai.signatureOffset)) continue;
        final f = ai.isArcFunc;
        if (f != null && f(head, n) == IsArcRes.no) continue;
        return fi;
      }
    }
    return -1;
  }

  int _matchFar(Uint8List w, int n, int off) {
    for (final fi in _formats) {
      final ai = codecs.formats[fi];
      if (ai.signatureOffset < off || ai.signatureOffset >= off + n) continue;
      for (final sig in ai.signatures) {
        final at = ai.signatureOffset - off;
        if (at + sig.length > n) continue;
        if (_eq(sig, w, at)) return fi;
      }
    }
    return -1;
  }

  static bool _eq(Uint8List sig, Uint8List data, int off) {
    for (var i = 0; i < sig.length; i++) {
      if (data[off + i] != sig[i]) return false;
    }
    return true;
  }

  /// [matches] on data already in memory (the start of the item and, when
  /// it is long enough, everything up to the far signatures).
  bool matchesBytes(Uint8List data, int n) => formatOfBytes(data, n) >= 0;

  /// [formatOf] on data already in memory.
  int formatOfBytes(Uint8List data, int n) {
    final h = _matchHead(data, n < _kHeadSize ? n : _kHeadSize);
    if (h >= 0) return h;
    for (final off in _farOffsets) {
      if (n < off + _kFarWindow) continue;
      final f = _matchFar(Uint8List.sublistView(data, off, off + _kFarWindow),
          _kFarWindow, off);
      if (f >= 0) return f;
    }
    return -1;
  }

  /// The bytes [matchesBytes] needs.
  int get bytesNeeded {
    var m = _kHeadSize;
    for (final off in _farOffsets) {
      if (off + _kFarWindow > m) m = off + _kFarWindow;
    }
    return m;
  }
}

/// One archive of the tree.
class _Node {
  final int id;
  final int parent;
  final int item;
  final int depth;
  final Arc arc;

  /// The link that opened it (null for node 0, owned by the caller).
  final ArchiveLink? link;

  /// Its items are images: every file item is tried.
  final bool containerContext;
  final String? tempFile;
  final int streamSize;
  final List<int> chain;
  String prefix = '';

  /// Item index to child node id.
  final Map<int, int> children = {};

  _Node(this.id, this.parent, this.item, this.depth, this.arc, this.link,
      this.containerContext, this.tempFile, this.streamSize, this.chain);

  InArchive get archive => arc.archive!;
  int get formatIndex => arc.formatIndex;
}

/// The IInArchive of a flattened tree (see the top of this file). It owns
/// the nested archives and, unless [keepTemps], the temporary files.
class FlatArc extends InArchive {
  final Codecs codecs;
  final InArchive inner;
  final int maxDepth;
  final OpenCallbackUI? ui;

  /// Temporary files are kept on [close] (the caller deletes [tempFolder]).
  final bool keepTemps;
  final String _tempBase;
  String? _tempFolder;
  final List<_Node> _nodes = [];
  late final NestSniffer _sniffer = NestSniffer(codecs);

  // the virtual items: node, index in the node, nested node or -1
  final List<int> _vNode = [];
  final List<int> _vIdx = [];
  final List<int> _vNested = [];
  final List<String> _vPath = [];
  List<int>? _propIds;

  FlatArc._(this.codecs, Arc root, this.maxDepth, this.ui, this.keepTemps,
      String? tempDir)
      : inner = root.archive!,
        _tempBase = tempDir ?? Directory.systemTemp.path {
    final shadow = Arc()
      ..archive = root.archive
      ..path = root.path
      ..defaultName = root.defaultName
      ..formatIndex = root.formatIndex;
    shadow.mTime.copyFrom(root.mTime);
    final ai = root.formatIndex >= 0 ? codecs.formats[root.formatIndex] : null;
    _nodes.add(_Node(0, -1, -1, 0, shadow, null, ai?.isContainer ?? false, null,
        root.fileSize, const []));
  }

  /// Builds the tree over [root] (an opened level of an [ArchiveLink]):
  /// with [layout] the nested archives it names are opened again (no item
  /// is tried), otherwise every item is tried as described above.
  static FlatArc build(Codecs codecs, Arc root,
      {int maxDepth = kDefaultNestDepth,
      OpenCallbackUI? ui,
      List<NestNodeSpec>? layout,
      bool keepTemps = false,
      String? tempDir}) {
    final f = FlatArc._(codecs, root, maxDepth, ui, keepTemps, tempDir);
    try {
      if (layout != null) {
        f._reopen(layout);
      } else {
        f._probe(f._nodes[0]);
      }
      f._buildEntries();
    } catch (_) {
      f._closeNodes();
      rethrow;
    }
    return f;
  }

  /// The folder that holds the temporary files (null when none was made).
  String? get tempFolder => _tempFolder;

  /// How the nested archives were reached, to open the same tree again.
  List<NestNodeSpec> get layout =>
      [for (final n in _nodes) NestNodeSpec(n.parent, n.item, n.tempFile)];

  /// The item indices from the archive to item [index] (the item index in
  /// each nested archive on the way, then in its own archive).
  List<int> chainOf(int index) {
    final n = _nodes[_vNode[index]];
    return [...n.chain, _vIdx[index]];
  }

  /// The format of the nested archive shown as the folder [index], or
  /// null for an item of an archive.
  String? nestedFormatOf(int index) {
    final c = _vNested[index];
    if (c < 0) return null;
    return codecs.formats[_nodes[c].formatIndex].name;
  }

  /// The number of nested archives.
  int get nestedCount => _nodes.length - 1;

  /// The errors and warnings of the nested archives, with their folders.
  List<(String, ArcErrorInfo)> get nestedErrors => [
        for (var i = 1; i < _nodes.length; i++)
          (_nodes[i].prefix, _nodes[i].arc.errorInfo)
      ];

  String _tempDirPath() {
    var t = _tempFolder;
    if (t == null) {
      t = Directory(_tempBase).createTempSync('zx_nest_').path;
      _tempFolder = t;
    }
    return t;
  }

  // ---- building ----

  void _probe(_Node node) {
    if (node.depth >= maxDepth) return;
    final a = node.archive;
    final n = a.numberOfItems;
    final noStream = <int>[];
    for (var i = 0; i < n; i++) {
      if (!_candidate(a, i)) continue;
      SeekableInStream? s;
      try {
        s = a.getStream(i);
      } on Object {
        s = null;
      }
      if (s == null) {
        noStream.add(i);
        continue;
      }
      try {
        if (!node.containerContext && !_sniffer.matches(s)) continue;
      } on Object {
        continue;
      }
      final child = _openChild(node, i, s, null);
      if (child != null) _probe(child);
    }
    if (noStream.isNotEmpty) _probeByExtract(node, noStream);
  }

  bool _candidate(InArchive a, int i) {
    try {
      if (archiveIsItemDir(a, i)) return false;
      if (archiveGetItemBoolProp(a, i, Kpid.isAnti)) return false;
      final hl = a.getProperty(i, Kpid.hardLink);
      if (hl is String && hl.isNotEmpty) return false;
      final sl = a.getProperty(i, Kpid.symLink);
      if (sl is String && sl.isNotEmpty) return false;
      final pm = a.getProperty(i, Kpid.posixAttrib);
      if (pm is int && (pm & 0xF000) != 0 && (pm & 0xF000) != 0x8000) {
        return false;
      }
      final size = a.getProperty(i, Kpid.size);
      if (size is int && size == 0) return false;
    } on Object {
      return false;
    }
    return true;
  }

  /// Items of an archive without random access: one pass over them keeps
  /// the start of each; an item that may be an archive goes on into a
  /// temporary file, which is then opened.
  void _probeByExtract(_Node node, List<int> items) {
    final cb = _HeadCallback(this, node.containerContext);
    try {
      node.archive.extract(items, false, cb);
    } on Object {
      // what was written before the error is used
    }
    cb.finishCurrent(false);
    for (final (i, path) in cb.files) {
      final FileInStream f;
      try {
        f = FileInStream.open(path);
      } on FileSystemException {
        continue;
      }
      final child = _openChild(node, i, f, path, file: f);
      if (child == null) {
        _deleteFile(path);
        continue;
      }
      _probe(child);
    }
  }

  String _newTempFile() {
    final dir = _tempDirPath();
    for (var k = 0;; k++) {
      final p = '$dir${Platform.pathSeparator}item$k.bin';
      final f = File(p);
      if (f.existsSync()) continue;
      f.createSync();
      return p;
    }
  }

  _Node? _openChild(_Node node, int item, SeekableInStream s, String? tempFile,
      {FileInStream? file}) {
    final name = extractFileNameFromPath(node.arc.getItemPath(item));
    final link = ArchiveLink();
    final op = OpenOptions()
      ..codecs = codecs
      ..types = const []
      ..excludedFormats = _excluded()
      ..stream = s
      ..filePath = name
      // a compressed tar is decoded to a temporary file (deleted when its
      // level is closed)
      ..compoundTempDir = _tempBase.endsWith(Platform.pathSeparator)
          ? _tempBase
          : '$_tempBase${Platform.pathSeparator}';
    int r;
    try {
      r = link.openStrict(op, ui, null);
    } on Object {
      r = HRes.eFail;
    }
    if (r != HRes.sOk || link.arcs.isEmpty) {
      link.close();
      file?.close();
      return null;
    }
    // a file opened as the temporary file is closed with the link
    if (file != null) link.arcs.first.fileStream = file;
    final last = link.arcs.last;
    final ai = codecs.formats[last.formatIndex];
    final multi = link.arcs.length > 1;
    // only an archive that opens without errors becomes a folder
    for (final x in link.arcs) {
      final e = x.errorInfo;
      if (e.getErrorFlags() != 0 || e.errorMessage.isNotEmpty) {
        link.close();
        return null;
      }
    }
    if (!node.containerContext && isNestLeafFormat(ai) && !multi) {
      link.close();
      return null;
    }
    // a cycle: the format and the size of a parent
    final size = s.length;
    for (var p = node;; p = _nodes[p.parent]) {
      if (p.formatIndex == last.formatIndex && p.streamSize == size) {
        link.close();
        return null;
      }
      if (p.parent < 0) break;
    }
    final ctx = ai.isContainer ||
        (isCompoundOuterFormat(ai) && !multi && node.containerContext);
    final child = _Node(_nodes.length, node.id, item, node.depth + 1, last,
        link, ctx, tempFile, size, [...node.chain, item]);
    _nodes.add(child);
    node.children[item] = child.id;
    return child;
  }

  List<int> _excluded() {
    final r = <int>[];
    for (var i = 0; i < codecs.formats.length; i++) {
      final ai = codecs.formats[i];
      if (ai.flagsHashHandler || ai.isSplit) r.add(i);
    }
    return r;
  }

  void _reopen(List<NestNodeSpec> layout) {
    for (var k = 1; k < layout.length; k++) {
      final spec = layout[k];
      if (spec.parent < 0 || spec.parent >= _nodes.length) {
        throw const SystemException(HRes.eFail);
      }
      final parent = _nodes[spec.parent];
      final t = spec.tempFile;
      _Node? child;
      if (t != null) {
        final f = FileInStream.open(t);
        child = _openChild(parent, spec.item, f, t, file: f);
      } else {
        final s = parent.archive.getStream(spec.item);
        if (s != null) child = _openChild(parent, spec.item, s, null);
      }
      if (child == null || child.id != k) {
        throw const SystemException(HRes.eFail);
      }
    }
  }

  void _buildEntries() {
    final sep = kDirSep;
    void emit(_Node node) {
      final a = node.archive;
      final n = a.numberOfItems;
      // one item that is an archive: the folder shows that archive (not
      // at the top: the items of the archive that was opened stay)
      final collapse = n == 1 && node.children.containsKey(0) && node.id != 0;
      for (var i = 0; i < n; i++) {
        final c = node.children[i];
        if (c != null && collapse) {
          _nodes[c].prefix = node.prefix;
          emit(_nodes[c]);
          continue;
        }
        final p = node.arc.getItemPath(i);
        if (node.id != 0 && (p.isEmpty || p == '.') && c == null) {
          // the top folder of a nested archive (a cpio made with
          // `find .`): the folder of the item stands for it
          continue;
        }
        final path = node.prefix.isEmpty ? p : '${node.prefix}$sep$p';
        _vNode.add(node.id);
        _vIdx.add(i);
        _vNested.add(c ?? -1);
        _vPath.add(path);
        if (c != null) {
          _nodes[c].prefix = path;
          emit(_nodes[c]);
        }
      }
    }

    emit(_nodes[0]);
  }

  // ---- IInArchive ----

  @override
  int open(SeekableInStream stream, int maxCheckStartPosition,
          ArchiveOpenCallback? callback) =>
      HRes.eNotImpl;

  void _closeNodes() {
    for (var i = _nodes.length - 1; i >= 1; i--) {
      final n = _nodes[i];
      try {
        n.link?.close();
      } on Object {
        // ignore
      }
    }
    if (_nodes.isNotEmpty) _nodes.removeRange(1, _nodes.length);
    final t = _tempFolder;
    if (t != null && !keepTemps) {
      _tempFolder = null;
      try {
        Directory(t).deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    }
  }

  @override
  void close() {
    _closeNodes();
    inner.close();
  }

  @override
  int get numberOfItems => _vNode.length;

  @override
  Object? getProperty(int index, int propId) {
    final node = _nodes[_vNode[index]];
    final i = _vIdx[index];
    final nested = _vNested[index];
    switch (propId) {
      case Kpid.path:
        return _vPath[index];
      case Kpid.isDir:
        if (nested >= 0) return true;
      case Kpid.hardLink:
        final v = node.archive.getProperty(i, propId);
        if (v is String && v.isNotEmpty && node.prefix.isNotEmpty) {
          return '${node.prefix}$kDirSep$v';
        }
        return v;
    }
    if (nested >= 0) {
      switch (propId) {
        case Kpid.attrib:
          return FileAttrib.directory |
              FileAttrib.unixExtension |
              (0x41ED << 16);
        case Kpid.posixAttrib:
          return 0x41ED;
        case Kpid.mTime:
        case Kpid.cTime:
        case Kpid.aTime:
          return node.archive.getProperty(i, propId);
      }
      return null;
    }
    return node.archive.getProperty(i, propId);
  }

  @override
  Object? getArchiveProperty(int propId) {
    if (propId == Kpid.mainSubfile) return null;
    return inner.getArchiveProperty(propId);
  }

  @override
  List<int> get itemPropIds {
    var p = _propIds;
    if (p == null) {
      final set = <int>{};
      p = <int>[];
      for (final n in _nodes) {
        for (final id in n.archive.itemPropIds) {
          if (set.add(id)) p.add(id);
        }
      }
      _propIds = p;
    }
    return p;
  }

  @override
  List<int> get archivePropIds => inner.archivePropIds;

  @override
  int get timePrec => inner.timePrec;

  @override
  SeekableInStream? getStream(int index) {
    if (_vNested[index] >= 0) return null;
    return _nodes[_vNode[index]].archive.getStream(_vIdx[index]);
  }

  int _sizeOf(int v) {
    if (_vNested[v] >= 0) return 0;
    final s = getProperty(v, Kpid.size);
    return s is int ? s : 0;
  }

  @override
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb) {
    final list = indices ?? [for (var i = 0; i < _vNode.length; i++) i];
    final byNode = <int, List<int>>{};
    var total = 0;
    for (final v in list) {
      if (v < 0 || v >= _vNode.length) continue;
      (byNode[_vNode[v]] ??= []).add(v);
      total += _sizeOf(v);
    }
    cb.setTotal(total);
    final askMode = testMode ? AskMode.test : AskMode.extract;
    var base = 0;
    final ids = byNode.keys.toList()..sort();
    for (final id in ids) {
      final vs = byNode[id]!;
      final map = <int, int>{};
      var size = 0;
      for (final v in vs) {
        if (_vNested[v] >= 0) {
          // the folder of a nested archive
          cb.getStream(v, askMode);
          cb.prepareOperation(askMode);
          cb.setOperationResult(OperationResult.ok);
          continue;
        }
        map[_vIdx[v]] = v;
        size += _sizeOf(v);
      }
      if (map.isEmpty) continue;
      final innerList = map.keys.toList()..sort();
      final m = cb is CryptoGetTextPassword
          ? _MapCbPw(cb, map, base)
          : _MapCb(cb, map, base);
      _nodes[id].archive.extract(innerList, testMode, m);
      base += size;
      cb.setCompleted(base);
    }
  }
}

void _deleteFile(String p) {
  try {
    File(p).deleteSync();
  } on FileSystemException {
    // ignore
  }
}

/// Forwards the extraction of one nested archive to the callback of the
/// tree, with the item indices of the tree.
class _MapCb extends ArchiveExtractCallback
    implements ArchiveExtractCallbackMessage2 {
  final ArchiveExtractCallback outer;
  final Map<int, int> map;
  final int base;
  bool _skip = false;
  _MapCb(this.outer, this.map, this.base);

  @override
  OutStream? getStream(int index, int askMode) {
    final v = map[index];
    if (v == null) {
      _skip = true;
      return null;
    }
    _skip = false;
    return outer.getStream(v, askMode);
  }

  @override
  void prepareOperation(int askMode) {
    if (!_skip) outer.prepareOperation(askMode);
  }

  @override
  void setOperationResult(int opRes) {
    if (!_skip) outer.setOperationResult(opRes);
  }

  @override
  void setTotal(int total) {}

  @override
  void setCompleted(int completeValue) =>
      outer.setCompleted(base + completeValue);

  @override
  void reportExtractResult(int indexType, int index, int opRes) {
    final o = outer;
    if (o is! ArchiveExtractCallbackMessage2) return;
    if (indexType == EventIndexType.inArcIndex) {
      final v = map[index];
      if (v == null) return;
      (o as ArchiveExtractCallbackMessage2)
          .reportExtractResult(indexType, v, opRes);
    } else {
      (o as ArchiveExtractCallbackMessage2)
          .reportExtractResult(indexType, index, opRes);
    }
  }
}

class _MapCbPw extends _MapCb implements CryptoGetTextPassword {
  _MapCbPw(super.outer, super.map, super.base);

  @override
  String cryptoGetTextPassword() =>
      (outer as CryptoGetTextPassword).cryptoGetTextPassword();
}

/// Keeps the start of each item; one that may be an archive (or every
/// one, in a container) goes on into a temporary file.
class _HeadCallback extends ArchiveExtractCallback {
  final FlatArc owner;
  final bool all;
  final List<(int, String)> files = [];
  late final int _need = owner._sniffer.bytesNeeded;
  _HeadSink? _cur;

  _HeadCallback(this.owner, this.all);

  @override
  OutStream? getStream(int index, int askMode) {
    finishCurrent(false);
    if (askMode != AskMode.extract) return null;
    return _cur = _HeadSink(this, index);
  }

  @override
  void setOperationResult(int opRes) =>
      finishCurrent(opRes == OperationResult.ok);

  void finishCurrent(bool ok) {
    final c = _cur;
    if (c == null) return;
    _cur = null;
    if (ok) c.decide();
    final path = c.close();
    if (path == null) return;
    if (ok) {
      files.add((c.index, path));
    } else {
      _deleteFile(path);
    }
  }
}

class _HeadSink implements OutStream {
  final _HeadCallback cb;
  final int index;
  BytesBuilder? _head = BytesBuilder(copy: true);
  bool _decided = false;
  FileOutStream? _out;
  String? _path;
  _HeadSink(this.cb, this.index);

  void decide() {
    if (_decided) return;
    _decided = true;
    final h = _head!.takeBytes();
    _head = null;
    if (cb.all || cb.owner._sniffer.matchesBytes(h, h.length)) {
      final p = cb.owner._newTempFile();
      _path = p;
      final o = FileOutStream.create(p);
      _out = o;
      if (h.isNotEmpty) o.write(h, 0, h.length);
    }
  }

  @override
  void write(Uint8List buf, int off, int len) {
    if (!_decided) {
      final h = _head!;
      final take = len < cb._need - h.length ? len : cb._need - h.length;
      h.add(Uint8List.sublistView(buf, off, off + take));
      if (h.length < cb._need) return;
      decide();
      off += take;
      len -= take;
      if (len <= 0) return;
    }
    _out?.write(buf, off, len);
  }

  @override
  void flush() => _out?.flush();

  String? close() {
    final o = _out;
    if (o != null) {
      o.flush();
      o.close();
    }
    return _path;
  }
}
