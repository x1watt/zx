// The zpaq journaling archive handler (not in 7-Zip): IInArchive and
// IOutArchive over the zpaq engine vendored from zpaq-flutter
// (lib/src/zpaq, see tool/sync_zpaq.sh and docs/architecture.md, section
// 14).
//
// A zpaq archive is a journal of versions: every update appends one, and
// older versions stay readable. The handler shows the archive as of its
// last version, or as of the version set with the "version" property
// (-mversion=N, ZxArchive.open(version: N)) before Open. Items are the
// files and folders present in that version, sorted by name (zpaq's
// order). Reading goes through the index of the engine (index.dart) and
// its block decoder (extract.dart decodeBlock, which checks every fragment
// against its SHA-1); the archive is read from the stream the UI opened,
// not from a file path, so nested and in memory archives work too.
//
// Writing (zpaq_update.dart) appends a new version as zpaq 7.15 does.

import 'dart:typed_data';

import '../../common/method_props.dart';
import '../../io/streams.dart';
import '../../zpaq/archive/archive_io.dart';
import '../../zpaq/archive/extract.dart' show decodeBlock;
import '../../zpaq/archive/index.dart';
import '../../zpaq/core/crc32.dart';
import '../../zpaq/core/io.dart';
import '../../zpaq/crypto/aes_ctr.dart';
import '../archive_types.dart';
import 'zpaq_update.dart';

/// The 13 byte locator tag that zpaq writes before each block.
final Uint8List zpaqLocatorTag = Uint8List.fromList(const [
  0x37, 0x6b, 0x53, 0x74, 0xa0, 0x31, 0x83, 0xd3, 0x8c, 0xb2, 0x28, 0xb0, //
  0xd3
]);

/// "zPQ" and the level byte (1 or 2) and block type 1 of a block header
/// without locator tag.
bool _isBlockHeader(Uint8List p, int off, int size) =>
    size >= off + 5 &&
    p[off] == 0x7a &&
    p[off + 1] == 0x50 &&
    p[off + 2] == 0x51 &&
    (p[off + 3] == 1 || p[off + 3] == 2) &&
    p[off + 4] == 1;

/// True when [p] starts like a plain (not encrypted) zpaq archive: the
/// locator tag, or a block header. 0: no, 1: yes, 2: need more bytes
/// (IsArc_zpaq, k_IsArc_Res_*).
int isArcZpaq(Uint8List p, int size) {
  if (size < 5) return 2;
  var tag = true;
  for (var i = 0; i < 13 && i < size; i++) {
    if (p[i] != zpaqLocatorTag[i]) {
      tag = false;
      break;
    }
  }
  if (tag) return size < 13 ? 2 : 1;
  return _isBlockHeader(p, 0, size) ? 1 : 0;
}

/// Reads an archive through a [SeekableInStream], decrypting with [aes]
/// by absolute offset (the engine's ArchiveInput reads a file path).
class ZpaqStreamInput implements ArchiveInput {
  final SeekableInStream _s;
  final AesCtr? _aes;
  @override
  final int length;
  final Uint8List _buf = Uint8List(1 << 16);
  int _bufStart = 0;
  int _bufLen = 0;
  int _pos;

  ZpaqStreamInput(this._s, this._aes)
      : length = _s.length,
        _pos = _aes == null ? 0 : 32;

  @override
  int get dataStart => _aes == null ? 0 : 32;

  @override
  int get position => _pos;

  @override
  void seek(int p) {
    _pos = p;
  }

  @override
  void close() {}

  bool _refill() {
    if (_pos >= length) return false;
    _s.position = _pos;
    final n = readFully(_s, _buf, 0, _buf.length);
    if (n <= 0) return false;
    _bufStart = _pos;
    _bufLen = n;
    _aes?.apply(_buf, 0, n, _pos);
    return true;
  }

  @override
  int get() {
    final i = _pos - _bufStart;
    if (i < 0 || i >= _bufLen) {
      if (!_refill()) return -1;
      return _buf[(_pos++) - _bufStart];
    }
    _pos++;
    return _buf[i];
  }

  @override
  int read(Uint8List buf, int off, int n) {
    var done = 0;
    while (done < n) {
      var i = _pos - _bufStart;
      if (i < 0 || i >= _bufLen) {
        if (!_refill()) break;
        i = 0;
      }
      var k = _bufLen - i;
      if (k > n - done) k = n - done;
      buf.setRange(off + done, off + done + k, _buf, i);
      done += k;
      _pos += k;
    }
    return done;
  }
}

/// FILETIME of a zpaq date (decimal YYYYMMDDHHMMSS, UTC).
int? zpaqDateToFileTime(int d) {
  if (d <= 0) return null;
  final t = DateTime.utc(d ~/ 10000000000, d ~/ 100000000 % 100,
      d ~/ 1000000 % 100, d ~/ 10000 % 100, d ~/ 100 % 100, d % 100);
  return t.microsecondsSinceEpoch * 10 + _kFileTimeUnixEpoch;
}

/// zpaq date of a FILETIME (seconds, UTC).
int fileTimeToZpaqDate(int ft) {
  final u = DateTime.fromMicrosecondsSinceEpoch(
      (ft - _kFileTimeUnixEpoch) ~/ 10,
      isUtc: true);
  return u.year * 10000000000 +
      u.month * 100000000 +
      u.day * 1000000 +
      u.hour * 10000 +
      u.minute * 100 +
      u.second;
}

const int _kFileTimeUnixEpoch = 116444736000000000;

/// One version of the archive, for listings.
class ZpaqVersionInfo {
  final int number;

  /// FILETIME of the update.
  final int time;
  final int added;
  final int deleted;

  /// Bytes of the data blocks of the update (compressed).
  final int packSize;
  const ZpaqVersionInfo(
      this.number, this.time, this.added, this.deleted, this.packSize);
}

/// A decoded data block: its bytes, the start of each fragment and one
/// flag per fragment (1: its SHA-1 matched).
class _Block {
  final Uint8List data;
  final Int64List starts;
  final Uint8List ok;
  final String? error;
  const _Block(this.data, this.starts, this.ok, [this.error]);
}

/// The zpaq handler.
class ZpaqHandler {
  SeekableInStream? _stream;
  ZpaqStreamInput? _input;
  ArchiveIndex? _idx;
  List<ZpaqEntry> _items = const [];

  /// The key of an encrypted archive, and its salt (the first 32 bytes).
  ZpaqKey? key;
  Uint8List? salt;

  /// Versions in the archive (all of them, whatever [openVersion]).
  int numVersions = 0;

  /// The version to show (null: the last one), set before [open].
  int? openVersion;

  /// Update settings (setProperties).
  final ZpaqUpdateOptions options = ZpaqUpdateOptions();

  final Map<int, String> _blockKinds = {};

  SeekableInStream? get stream => _stream;
  ArchiveIndex? get index => _idx;

  /// The archive is shown as of a version before the last one.
  bool get isOlderVersion =>
      _idx != null && _idx!.versions.length < numVersions;

  /// The engine input of the open archive (decrypting).
  ZpaqStreamInput? get input => _input;

  int get numberOfItems => _items.length;
  List<ZpaqEntry> get items => _items;

  List<ZpaqVersionInfo> get versions => [
        for (final v in _idx?.versions ?? const <ZpaqVersion>[])
          ZpaqVersionInfo(v.number, zpaqDateToFileTime(v.date) ?? 0,
              v.updates, v.deletes, v.csize)
      ];

  /// IInArchive::Open. [getPassword] is asked for an encrypted archive
  /// (null: can not open it). False when the stream is not a zpaq archive
  /// or the password is wrong.
  bool open(SeekableInStream stream, {String? Function()? getPassword}) {
    close();
    final len = stream.length;
    if (len < 5) return false;
    final head = Uint8List(48);
    stream.position = 0;
    final n = readFully(stream, head, 0, head.length);
    AesCtr? aes;
    if (isArcZpaq(head, n) != 1) {
      // an encrypted archive: 32 random bytes of salt, then the blocks
      if (n < 32 + 5 || getPassword == null) return false;
      final pw = getPassword();
      if (pw == null) return false;
      final k = ZpaqKey.fromPassword(pw);
      final s = Uint8List.fromList(Uint8List.sublistView(head, 0, 32));
      aes = k.cipherFor(s);
      final probe = Uint8List.fromList(Uint8List.sublistView(head, 32, n));
      aes.apply(probe, 0, probe.length, 32);
      if (isArcZpaq(probe, probe.length) != 1) return false;
      key = k;
      salt = s;
    }
    final input = ZpaqStreamInput(stream, aes);
    ArchiveIndex idx;
    try {
      idx = readIndex(input, untilVersion: openVersion);
      if (openVersion != null) {
        // the number of versions after the one shown
        numVersions = readIndex(ZpaqStreamInput(stream, aes)).versions.length;
      } else {
        numVersions = idx.versions.length;
      }
    } on ZpaqException {
      key = null;
      salt = null;
      return false;
    }
    _stream = stream;
    _input = input;
    _idx = idx;
    _items = idx.entries;
    return true;
  }

  void close() {
    _stream = null;
    _input = null;
    _idx = null;
    _items = const [];
    _blockKinds.clear();
    key = null;
    salt = null;
    numVersions = 0;
  }

  static const List<int> itemPropIds = [
    Kpid.path,
    Kpid.isDir,
    Kpid.size,
    Kpid.mTime,
    Kpid.attrib,
    Kpid.posixAttrib,
    Kpid.crc,
    Kpid.encrypted,
    Kpid.method,
    ZxKpid.version,
  ];

  static const List<int> archivePropIds = [
    Kpid.method,
    ZxKpid.numVersions,
    ZxKpid.version,
    Kpid.encrypted,
  ];

  /// The attributes of [e] as 7-Zip's kpidAttrib: the POSIX mode in the
  /// high 16 bits with FILE_ATTRIBUTE_UNIX_EXTENSION, or the Windows ones.
  static int? attribOf(ZpaqEntry e) {
    final w = e.windowsAttributes;
    if (w != null) return w;
    final m = e.unixMode;
    var a = e.isDirectory ? FileAttrib.directory : 0;
    if (m != null) {
      a |= FileAttrib.unixExtension | (m << 16);
      if ((m & 0x92) == 0) a |= FileAttrib.readOnly;
    } else if (e.attr == 0 && !e.isDirectory) {
      return null;
    }
    return a;
  }

  Object? getProperty(int index, int propId) {
    if (index < 0 || index >= _items.length) return null;
    final e = _items[index];
    switch (propId) {
      case Kpid.path:
        var n = e.name;
        if (n.endsWith('/') && n.length > 1) n = n.substring(0, n.length - 1);
        return n;
      case Kpid.isDir:
        return e.isDirectory;
      case Kpid.size:
        return e.isDirectory || e.size < 0 ? null : e.size;
      case Kpid.mTime:
        return zpaqDateToFileTime(e.date);
      case Kpid.attrib:
        return attribOf(e);
      case Kpid.posixAttrib:
        return e.unixMode;
      case Kpid.crc:
        final c = e.franz?.crc32 ?? '';
        return c.length == 8 ? int.tryParse(c, radix: 16) : null;
      case Kpid.encrypted:
        return key != null;
      case Kpid.method:
        if (e.isDirectory || e.ptr.isEmpty) return null;
        return _kindOfFragment(e.ptr.first);
      case ZxKpid.version:
        return e.version;
    }
    return null;
  }

  Object? getArchiveProperty(int propId) {
    final idx = _idx;
    if (idx == null) return null;
    switch (propId) {
      case Kpid.phySize:
        return _stream?.length;
      case Kpid.method:
        final kinds = <String>{};
        for (var b = 0; b < idx.blocks.length; b++) {
          final k = _kindOfBlock(b);
          if (k != null) kinds.add(k);
        }
        final l = kinds.toList()..sort();
        return l.isEmpty ? null : l.join(' ');
      case ZxKpid.numVersions:
        return numVersions;
      case ZxKpid.version:
        return idx.versions.length;
      case Kpid.encrypted:
        return key != null;
      case Kpid.warning:
        return idx.incomplete
            ? 'The last update is incomplete (it is ignored, the next '
                'update overwrites it)'
            : null;
    }
    return null;
  }

  String? _kindOfFragment(int frag) {
    final b = _idx!.blockOf(frag);
    return b < 0 ? null : _kindOfBlock(b);
  }

  /// What the block header says of its model: "Store" (no model), "LZ77"
  /// (a postprocessor without context model: methods 1 and 2) or "CM"
  /// (context models: methods 3 to 5). The zpaq method number itself is not
  /// stored in the archive.
  String? _kindOfBlock(int b) {
    final cached = _blockKinds[b];
    if (cached != null) return cached;
    final input = _input!;
    // the block starts at or a little after its offset (the engine finds
    // it by its locator tag)
    final h = Uint8List(64);
    input.seek(_idx!.blocks[b].offset);
    final n = input.read(h, 0, h.length);
    String? kind;
    for (var o = 0; o + 12 <= n; o++) {
      if (_isBlockHeader(h, o, n)) {
        final pm = h[o + 10], nComp = h[o + 11];
        kind = nComp != 0 ? 'CM' : (pm == 0 ? 'Store' : 'LZ77');
        break;
      }
    }
    if (kind != null) _blockKinds[b] = kind;
    return kind;
  }

  // ---- extraction ----

  _Block _decode(int b) {
    final idx = _idx!;
    final bl = idx.blocks[b];
    final sha1s = Uint8List.fromList(Uint8List.sublistView(
        idx.ht.sha1Bytes(), 20 * bl.start, 20 * (bl.start + bl.frags)));
    final usizes = Int32List(bl.frags);
    final starts = Int64List(bl.frags + 1);
    for (var k = 0; k < bl.frags; ++k) {
      final u = idx.ht.usize(bl.start + k);
      usizes[k] = u;
      starts[k + 1] = starts[k] + (u < 0 ? 0 : u);
    }
    try {
      final (data, ok) = decodeBlock(_input!, bl.offset, sha1s, usizes);
      return _Block(data, starts, ok);
    } on ZpaqException catch (e) {
      return _Block(Uint8List(0), starts, Uint8List(bl.frags), e.message);
    }
  }

  /// IInArchive::Extract. Blocks are decoded once while items still need
  /// them (at most [cacheBytes] of decoded blocks are kept).
  void extract(List<int>? indices, bool testMode, ArchiveExtractCallback cb,
      {int cacheBytes = 192 << 20}) {
    final idx = _idx;
    if (idx == null) return;
    final list = indices ?? [for (var i = 0; i < _items.length; i++) i];
    var total = 0;
    final refs = <int, int>{};
    for (final i in list) {
      final e = _items[i];
      if (e.isDirectory) continue;
      if (e.size > 0) total += e.size;
      for (final j in e.ptr) {
        final b = idx.blockOf(j);
        if (b >= 0) refs[b] = (refs[b] ?? 0) + 1;
      }
    }
    cb.setTotal(total);
    // decoded blocks, least recently used first
    final cache = <int, _Block>{};
    var cached = 0;
    var completed = 0;
    final askMode = testMode ? AskMode.test : AskMode.extract;
    for (final i in list) {
      final e = _items[i];
      final out = cb.getStream(i, askMode);
      cb.prepareOperation(askMode);
      if (e.isDirectory) {
        cb.setOperationResult(OperationResult.ok);
        continue;
      }
      var res = OperationResult.ok;
      final crc = Crc32();
      var size = 0;
      for (final j in e.ptr) {
        final b = idx.blockOf(j);
        if (b >= 0) {
          final left = (refs[b] ?? 1) - 1;
          refs[b] = left;
        }
        if (res != OperationResult.ok) continue;
        if (b < 0) {
          res = OperationResult.unavailable;
          continue;
        }
        var blk = cache.remove(b);
        if (blk == null) {
          blk = _decode(b);
          cached += blk.data.length;
        }
        cache[b] = blk;
        if (blk.error != null) {
          res = OperationResult.dataError;
        } else {
          final k = j - idx.blocks[b].start;
          if (blk.ok[k] != 1) {
            res = OperationResult.crcError;
          } else {
            final s = blk.starts[k], len = blk.starts[k + 1] - s;
            if (len > 0) {
              out?.write(blk.data, s, len);
              crc.add(blk.data, s, s + len);
              size += len;
              completed += len;
            }
          }
        }
        if (refs[b] == 0) {
          final d = cache.remove(b);
          if (d != null) cached -= d.data.length;
        }
        while (cached > cacheBytes && cache.length > 1) {
          final first = cache.keys.first;
          cached -= cache.remove(first)!.data.length;
        }
        cb.setCompleted(completed);
      }
      if (res == OperationResult.ok) {
        if (e.size >= 0 && size != e.size) {
          res = OperationResult.dataError;
        } else {
          final want = getProperty(i, Kpid.crc);
          if (want is int && want != crc.value) res = OperationResult.crcError;
        }
      }
      cb.setOperationResult(res);
    }
  }

  /// IInArchiveGetStream::GetStream: random access to a file, decoded a
  /// block at a time.
  SeekableInStream? getStream(int index) {
    if (_idx == null || index < 0 || index >= _items.length) return null;
    final e = _items[index];
    if (e.isDirectory || e.size < 0) return null;
    for (final j in e.ptr) {
      if (_idx!.blockOf(j) < 0) return null;
    }
    return _ZpaqItemStream(this, e);
  }

  // ---- ISetProperties ----

  void setProperties(List<MapEntry<String, PropVariant>> props) {
    options.reset();
    for (final p in props) {
      final name = p.key.toLowerCase();
      final value = p.value;
      if (name.isEmpty) invalidArg();
      if (name == 'version' || name == 'ver') {
        final v = parsePropToUInt32('', value, 0);
        openVersion = v == 0 ? null : v;
        continue;
      }
      if (name.startsWith('x')) {
        var level = parsePropToUInt32(name.substring(1), value, 1);
        if (level > 5) level = 5;
        options.method = '$level';
        continue;
      }
      if (name == 'm' || name == '0') {
        if (value.vt == VarType.ui4 || value.vt == VarType.ui8) {
          options.method = '${value.intValue}';
        } else if (value.vt == VarType.bstr) {
          options.method = value.stringValue;
        } else {
          invalidArg('zpaq: bad method');
        }
        final m = options.method;
        if (m.isEmpty || !RegExp(r'^[0-9x]').hasMatch(m)) {
          invalidArg('zpaq: the method must begin with 0 to 5 or x');
        }
        continue;
      }
      if (name == 'fragment' || name == 'frag') {
        final f = parsePropToUInt32('', value, 6);
        if (f > 19) invalidArg('zpaq: fragment must be 0 to 19');
        options.fragment = f;
        continue;
      }
      if (name == 'hash') {
        final s = value.vt == VarType.bstr ? value.stringValue.toLowerCase() : '';
        switch (s) {
          case 'xxh64' || 'xxhash64' || 'xxhash':
            options.storeHashes = true;
            options.sha1 = false;
          case 'sha1' || 'sha-1':
            options.storeHashes = true;
            options.sha1 = true;
          case 'off' || 'none' || '-':
            options.storeHashes = false;
          default:
            invalidArg('zpaq: hash must be xxh64, sha1 or off');
        }
        continue;
      }
      if (name.startsWith('mt')) {
        // accepted: the update runs on the operation's isolate (see
        // docs/architecture.md, section 14)
        continue;
      }
      if (name.startsWith('memuse') ||
          name == 'tm' ||
          name == 'tc' ||
          name == 'ta' ||
          name == 'cp') {
        continue;
      }
      invalidArg('zpaq: unknown property ${p.key}');
    }
  }

  /// IOutArchive::UpdateItems (zpaq_update.dart).
  void updateItems(
          SeekableOutStream out, int numItems, ArchiveUpdateCallback cb) =>
      zpaqUpdateItems(this, out, numItems, cb);
}

/// The data of one file, read by fragment from the decoded blocks.
class _ZpaqItemStream extends SeekableInStream {
  final ZpaqHandler _h;
  final ZpaqEntry _e;
  final Int64List _offsets; // start of each fragment in the file
  int _pos = 0;
  int _block = -1;
  _Block? _data;

  _ZpaqItemStream(this._h, this._e) : _offsets = Int64List(_e.ptr.length + 1) {
    final ht = _h.index!.ht;
    for (var k = 0; k < _e.ptr.length; k++) {
      final u = ht.usize(_e.ptr[k]);
      _offsets[k + 1] = _offsets[k] + (u < 0 ? 0 : u);
    }
  }

  @override
  int get length => _offsets.last;

  @override
  int get position => _pos;

  @override
  set position(int value) => _pos = value;

  @override
  int read(Uint8List buf, int off, int len) {
    if (_pos >= length || len <= 0) return 0;
    // the fragment holding _pos
    var lo = 0, hi = _e.ptr.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_offsets[mid] <= _pos) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final j = _e.ptr[lo];
    final idx = _h.index!;
    final b = idx.blockOf(j);
    if (b != _block) {
      _data = _h._decode(b);
      _block = b;
    }
    final d = _data!;
    final k = j - idx.blocks[b].start;
    if (d.error != null) {
      throw SevenZipException('zpaq: ${d.error}', SevenZipError.data);
    }
    if (d.ok[k] != 1) {
      throw const SevenZipException(
          'zpaq: fragment checksum error', SevenZipError.crc);
    }
    final inFrag = _pos - _offsets[lo];
    var n = _offsets[lo + 1] - _pos;
    if (n > len) n = len;
    final s = d.starts[k] + inFrag;
    buf.setRange(off, off + n, d.data, s);
    _pos += n;
    return n;
  }
}
