// IOutArchive::UpdateItems of the zpaq handler: appends one version to
// the journal, as zpaq 7.15's Jidac::add does (the one thread path of
// zpaq-flutter's add.dart, taking the files from the update callback
// instead of the disk).
//
// The UI writes every update to a new file (7-Zip's temporary archive and
// rename), so the old archive is first copied byte for byte (encrypted
// archives too: the key stream depends only on the offset), then the new
// version follows:
// - new or changed files are cut into fragments by zpaq's rolling hash;
//   a fragment whose SHA-1 is already in the archive is not stored again
//   (deduplication against every version);
// - the new fragments go to blocks built with zpaq's heuristics (sorted by
//   extension and size, block ends at file boundaries, redundancy, text
//   and x86 detection) and compressed with the method (-mx, -mm);
// - kept items cost nothing; a renamed item gets an index entry with its
//   old fragment list (nothing is compressed again) and a deletion of the
//   old name; items of the old archive that are not in the update are
//   written as deletions. Old versions stay complete.
//
// The compression runs on the isolate of the operation, block after block
// (UpdateItems is synchronous and can not wait for worker isolates).

import 'dart:convert';
import '../../host/io.dart' show Platform;
import 'dart:typed_data';

import '../../io/streams.dart';
import '../../zpaq/archive/archive_io.dart';
import '../../zpaq/archive/franz.dart';
import '../../zpaq/archive/index.dart';
import '../../zpaq/core/crc32.dart';
import '../../zpaq/core/io.dart';
import '../../zpaq/core/lzbuffer.dart';
import '../../zpaq/core/method.dart';
import '../../zpaq/core/sha1.dart';
import '../../zpaq/core/xxhash64.dart';
import '../../zpaq/crypto/aes_ctr.dart';
import '../archive_types.dart';
import 'zpaq_handler.dart';

/// The -m settings of an update.
class ZpaqUpdateOptions {
  /// zpaq method: "0" to "5", optionally with a block size digit ("14"),
  /// or an explicit method string ("x4.3ci1").
  String method = '1';

  /// Log2 of the average fragment size in KiB (zpaq -fragment, 6 = 64 KiB).
  int fragment = 6;

  /// Store zpaqfranz's per file hash and CRC-32 (read by zpaqfranz t/v;
  /// zpaq 7.15 ignores them).
  bool storeHashes = true;

  /// SHA-1 instead of XXHASH64 for the file hash.
  bool sha1 = false;

  void reset() {
    method = '1';
    fragment = 6;
    storeHashes = true;
    sha1 = false;
  }
}

/// A writer to the new archive, encrypting by absolute offset.
class _Out extends ZWriter {
  final SeekableOutStream _s;
  final AesCtr? _aes;
  final Uint8List _buf = Uint8List(1 << 16);
  int _bufLen = 0;
  int _pos; // file offset of _buf[0]

  _Out(this._s, this._aes) : _pos = _s.position;

  int get position => _pos + _bufLen;

  void flush() {
    if (_bufLen == 0) return;
    _aes?.apply(_buf, 0, _bufLen, _pos);
    _s.position = _pos;
    _s.write(_buf, 0, _bufLen);
    _pos += _bufLen;
    _bufLen = 0;
  }

  void seek(int p) {
    flush();
    _pos = p;
  }

  @override
  void put(int c) {
    if (_bufLen == _buf.length) flush();
    _buf[_bufLen++] = c;
  }

  @override
  void write(Uint8List buf, int off, int n) {
    while (n > 0) {
      if (_bufLen == _buf.length) flush();
      var k = _buf.length - _bufLen;
      if (k > n) k = n;
      _buf.setRange(_bufLen, _bufLen + k, buf, off);
      _bufLen += k;
      off += k;
      n -= k;
    }
  }
}

/// A file or folder of the new version.
class _Item {
  final int index; // in the update
  final String name; // zpaq form: '/' separated, folders end with '/'
  final int date;
  final int attr;
  final int size;
  final bool newData;
  final ZpaqEntry? old; // the item of the old archive it comes from
  Uint32List ptr = Uint32List(0);
  bool data = false; // read in this update
  bool failed = false;
  int? xxhash;
  Uint8List? sha1;
  int crc = 0;
  int sortHi = 0, sortLo = 0;
  _Item(this.index, this.name, this.date, this.attr, this.size, this.newData,
      this.old);
  bool get isDir => name.endsWith('/');
}

const List<int> _dt = [
  160, 80, 53, 40, 32, 26, 22, 20, 17, 16, 14, 13, 12, 11, 10, 10, //
  9, 8, 8, 8, 7, 7, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5,
  4, 4, 4, 4, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 3, 3,
  3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
];

bool _isAlnum(int c) =>
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);

/// Fragment ids by SHA-1 (libzpaq's HTIndex, as a map on the first 8
/// bytes of the hash).
class _FragIndex {
  final FragmentTable ht;
  final Map<int, Object> _m = {}; // int id, or List<int> of ids
  int _indexed = 1;
  _FragIndex(this.ht) {
    update();
  }

  static int _key(Uint8List h, int o) {
    var k = 0;
    for (var i = 0; i < 8; i++) {
      k = (k << 8) | h[o + i];
    }
    return k;
  }

  int find(Uint8List sha1) {
    final v = _m[_key(sha1, 0)];
    if (v == null) return 0;
    if (v is int) return ht.sha1Equals(v, sha1) ? v : 0;
    for (final id in v as List<int>) {
      if (ht.sha1Equals(id, sha1)) return id;
    }
    return 0;
  }

  void update() {
    final all = ht.sha1Bytes();
    while (_indexed < ht.length) {
      final id = _indexed++;
      if (ht.usize(id) < 0) continue;
      var zero = true;
      for (var k = 0; k < 20; ++k) {
        if (all[20 * id + k] != 0) {
          zero = false;
          break;
        }
      }
      if (zero) continue;
      final key = _key(all, 20 * id);
      final v = _m[key];
      if (v == null) {
        _m[key] = id;
      } else if (v is int) {
        if (!ht.sha1Equals(v, Uint8List.sublistView(all, 20 * id, 20 * id + 20))) {
          _m[key] = <int>[v, id];
        }
      } else {
        (v as List<int>).add(id);
      }
    }
  }
}

bool _ptrEqual(Uint32List a, Uint32List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; ++i) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The zpaq attributes of an item from the callback's kpidAttrib: 'u' and
/// the POSIX mode, or 'w' and the Windows attributes (0: none).
int _zpaqAttr(Object? attrib, bool isDir) {
  if (attrib is! int) return 0;
  if ((attrib & FileAttrib.unixExtension) != 0) {
    var mode = (attrib >> 16) & 0xFFFF;
    if ((mode & 0xF000) == 0) mode |= isDir ? 0x4000 : 0x8000;
    return 0x75 + (mode << 8);
  }
  var w = attrib & 0xFFFFFFFF;
  if (isDir) w |= FileAttrib.directory;
  return 0x77 + (w << 8);
}

String _itemName(Object? path, bool isDir) {
  if (path is! String || path.isEmpty) {
    throw const SevenZipException('zpaq: an item has no name');
  }
  var n = Platform.isWindows ? path.replaceAll('\\', '/') : path;
  while (n.length > 1 && n.endsWith('/')) {
    n = n.substring(0, n.length - 1);
  }
  return isDir ? '$n/' : n;
}

/// Writes the 8 byte transaction header block (method 0, fixed size).
void _writeHeader(ZWriter out, int date, int cdata, int htsize) {
  final b = ZBuffer(8)..putLE(cdata, 8);
  compressBlock(b, out, '0',
      filename: 'jDC${itos(date, 14)}c${itos(htsize, 10)}', comment: 'jDC\x01');
}

int _dateOf(Object? ft) {
  if (ft is int && ft > 0) return fileTimeToZpaqDate(ft);
  return fileTimeToZpaqDate(
      DateTime.now().toUtc().microsecondsSinceEpoch * 10 + 116444736000000000);
}

/// IOutArchive::UpdateItems of [h] (see the top of the file).
void zpaqUpdateItems(ZpaqHandler h, SeekableOutStream outStream, int numItems,
    ArchiveUpdateCallback cb) {
  if (h.isOlderVersion) {
    throw const SevenZipException(
        'zpaq: the archive is open as of an older version (-mversion) and '
        'can not be updated',
        SevenZipError.unsupported);
  }
  final opt = h.options;
  final opCb =
      cb is ArchiveUpdateCallbackFile ? cb as ArchiveUpdateCallbackFile : null;
  final src = h.stream;
  final hasOld = src != null && h.index != null;

  // ---- the key ----
  String? pw;
  if (cb is CryptoGetTextPassword2) {
    pw = (cb as CryptoGetTextPassword2).cryptoGetTextPassword2();
    if (pw != null && pw.isEmpty) pw = null;
  }
  ZpaqKey? key;
  Uint8List? salt;
  if (hasOld && h.key != null) {
    key = h.key;
    salt = h.salt;
    if (pw != null) {
      final k2 = ZpaqKey.fromPassword(pw);
      for (var i = 0; i < 32; i++) {
        if (k2.passwordHash[i] != key!.passwordHash[i]) {
          throw const SevenZipException(
              'zpaq: the archive is encrypted with another password',
              SevenZipError.unsupported);
        }
      }
    }
  } else if (pw != null) {
    if (hasOld && h.index!.versions.isNotEmpty) {
      throw const SevenZipException(
          'zpaq: an archive can only be encrypted when it is created',
          SevenZipError.unsupported);
    }
    key = ZpaqKey.fromPassword(pw);
    salt = randomSalt();
  }

  final idx = hasOld ? h.index! : ArchiveIndex();
  final ht = idx.ht;
  final dt = idx.files; // the last version, deleted markers included

  // ---- method and block size (zpaq's defaults) ----
  var method = opt.method.isEmpty ? '1' : opt.method;
  if (method.length == 1) {
    final c = method.codeUnitAt(0);
    method += (c >= 50 && c <= 57) ? '6' : '4';
  }
  final fragment = opt.fragment;
  final logBlocksize = 20 +
      (int.tryParse(RegExp(r'^\d+').stringMatch(method.substring(1)) ?? '0') ??
          0);
  if (logBlocksize < 20 || logBlocksize > 31) {
    throw const SevenZipException(
        'zpaq: the block size digit must be 0 to 11', SevenZipError.unsupported);
  }
  final blocksize = (1 << logBlocksize) - 4096;
  final maxFragment = fragment > 19 || (8128 << fragment) > blocksize - 12
      ? blocksize - 12
      : 8128 << fragment;
  final minFragment = fragment > 25 || (64 << fragment) > maxFragment
      ? maxFragment
      : 64 << fragment;

  // ---- the items of the new version ----
  final items = <_Item>[];
  final finalNames = <String>{};
  var totalSize = 0;
  for (var i = 0; i < numItems; i++) {
    final info = cb.getUpdateItemInfo(i);
    ZpaqEntry? old;
    if (info.indexInArchive >= 0) {
      if (!hasOld || info.indexInArchive >= h.numberOfItems) {
        throw const SevenZipException('zpaq: bad index in archive');
      }
      old = h.items[info.indexInArchive];
    }
    if (!info.newData && !info.newProps) {
      // kept as it is: nothing to write
      finalNames.add(old!.name);
      opCb?.reportOperation(EventIndexType.inArcIndex, info.indexInArchive,
          UpdateNotifyOp.replicate);
      continue;
    }
    if (cb.getProperty(i, Kpid.isAnti) == true) continue;
    final isDir = info.newProps || old == null
        ? cb.getProperty(i, Kpid.isDir) == true
        : old.isDirectory;
    final name = info.newProps || old == null
        ? _itemName(cb.getProperty(i, Kpid.path), isDir)
        : old.name;
    int date, attr;
    if (info.newProps || old == null) {
      date = _dateOf(cb.getProperty(i, Kpid.mTime));
      attr = _zpaqAttr(cb.getProperty(i, Kpid.attrib), isDir);
    } else {
      date = old.date;
      attr = old.attr;
    }
    var size = 0;
    if (info.newData && !isDir) {
      final s = cb.getProperty(i, Kpid.size);
      size = s is int ? s : 0;
      totalSize += size;
    } else if (old != null && !isDir) {
      size = old.size < 0 ? 0 : old.size;
    }
    final it = _Item(i, name, date, attr, size, info.newData && !isDir, old);
    if (!info.newData && old != null) it.ptr = old.ptr;
    items.add(it);
    finalNames.add(name);
  }

  // new data in zpaq's order: first 5 bytes of the extension, then
  // decreasing size in 16 KiB units, as one 64 bit number (hi, lo)
  final vf = <_Item>[];
  for (final p in items) {
    if (!p.newData) continue;
    var hi = 0, lo = 0, sp = 0;
    for (final c0 in utf8.encode(p.name)) {
      var c = c0;
      if (c >= 65 && c <= 90) c += 32;
      if (c == 47) {
        sp = 0;
        hi = lo = 0;
      } else if (c == 46) {
        sp = 8;
        hi = lo = 0;
      } else if (sp > 3) {
        --sp;
        if (sp >= 4) {
          hi += c << ((sp - 4) * 8);
        } else {
          lo += c << 24;
        }
      }
    }
    var s = p.size >> 14;
    if (s >= (1 << 24)) s = (1 << 24) - 1;
    p.sortHi = hi;
    p.sortLo = lo + (1 << 24) - s - 1;
    vf.add(p);
  }
  vf.sort((a, b) {
    if (a.sortHi != b.sortHi) return a.sortHi - b.sortHi;
    if (a.sortLo != b.sortLo) return a.sortLo - b.sortLo;
    return compareNames(a.name, b.name);
  });

  // version date, strictly after the last one
  var date = _dateOf(null);
  if (idx.versions.isNotEmpty) {
    var last = 0;
    for (final v in idx.versions) {
      if (v.date > last) last = v.date;
    }
    if (last >= date) {
      final t = zpaqDateToFileTime(last)! + 10000000;
      date = fileTimeToZpaqDate(t);
    }
  }

  cb.setTotal(totalSize);

  // ---- the old archive, byte for byte ----
  final out = _Out(outStream, key?.cipherFor(salt!));
  if (hasOld) {
    final end = idx.appendOffset;
    final buf = Uint8List(1 << 16);
    src.position = 0;
    var done = 0;
    outStream.position = 0;
    while (done < end) {
      var n = end - done;
      if (n > buf.length) n = buf.length;
      final r = readFully(src, buf, 0, n);
      if (r != n) {
        throw const SevenZipException(
            'zpaq: unexpected end of the archive', SevenZipError.unexpectedEnd);
      }
      outStream.write(buf, 0, n);
      done += n;
    }
    out.seek(end);
  } else if (key != null) {
    outStream.position = 0;
    outStream.write(salt!, 0, 32);
    out.seek(32);
  }
  final headerPos = out.position;
  final htsize = ht.length;
  _writeHeader(out, date, -1, htsize);
  final headerEnd = out.position;

  // ---- data blocks ----
  final fi = _FragIndex(ht);
  final tables = LzHashTables();
  final blocklist = <int>[];
  final csize = <int>[];
  final sb = ZBuffer(blocksize + 4096 - 128);
  var frags = 0, redundancy = 0, text = 0, exe = 0;
  const on = 4;
  final o1prev = Uint8List(on * 256);
  var completed = 0;

  void flushBlock() {
    for (var i = ht.length - frags; i < ht.length; ++i) {
      sb.putLE(ht.usize(i), 4);
    }
    sb.putLE(0, 4);
    sb.putLE(frags, 4);
    var m = method;
    if (method.codeUnitAt(0) >= 48 && method.codeUnitAt(0) <= 57) {
      m += ',${redundancy ~/ (sb.size ~/ 256 + 1)},'
          '${(exe > frags ? 1 : 0) * 2 + (text > frags ? 1 : 0)}';
    }
    final first = ht.length - frags;
    final start = out.position;
    compressBlock(sb, out, m,
        filename: 'jDC${itos(date, 14)}d${itos(first, 10)}',
        comment: 'jDC\x01',
        tables: tables);
    csize.add(out.position - start);
    blocklist.add(first);
    sb.clear();
    frags = redundancy = text = exe = 0;
    o1prev.fillRange(0, o1prev.length, 0);
  }

  final buf = Uint8List(1 << 16);
  final frag = Uint8List(maxFragment);
  final o1 = Uint8List(256);
  final fragSha = Sha1();
  final limit = fragment <= 22 ? 1 << (22 - fragment) : 0;

  for (final p in vf) {
    final stream = cb.getStream(p.index);
    if (stream == null) {
      // could not be read: the old version of the name stays
      p.failed = true;
      continue;
    }
    opCb?.reportOperation(EventIndexType.outArcIndex, p.index,
        p.old == null ? UpdateNotifyOp.add : UpdateNotifyOp.update);
    final ptrs = <int>[];
    final crc = Crc32();
    final xx = opt.storeHashes && !opt.sha1 ? XxHash64() : null;
    final fileSha = opt.storeHashes && opt.sha1 ? Sha1() : null;
    var fj = 0;
    try {
      o1.fillRange(0, 256, 0);

      // one fragment of [sz] bytes in [frag], with its order 1 table o1
      // (the byte loop below keeps its state in locals, not captured here)
      void fragmentDone(int sz, int hits) {
        crc.add(frag, 0, sz);
        xx?.add(frag, 0, sz);
        fileSha?.add(frag, 0, sz);
        fragSha.add(frag, 0, sz);
        final sha1result = fragSha.digest();
        var htptr = fi.find(sha1result);
        if (htptr == 0) {
          // analyze the fragment for redundancy, x86 and text
          var text1 = 0, exe1 = 0;
          var h1 = sz;
          final o1ct = Uint8List(256);
          for (var i = 0; i < 256; ++i) {
            if (o1ct[o1[i]] < 255) h1 -= (sz * _dt[o1ct[o1[i]]++]) >> 15;
            if (o1[i] == 32 && (_isAlnum(i) || i == 46 || i == 44)) ++text1;
            if (o1[i] != 0 &&
                (i < 9 ||
                    i == 11 ||
                    i == 12 ||
                    (i >= 14 && i <= 31) ||
                    i >= 240)) {
              --text1;
            }
            if (i >= 192 &&
                i < 240 &&
                o1[i] != 0 &&
                (o1[i] < 128 || o1[i] >= 192)) {
              --text1;
            }
            if (o1[i] == 139) ++exe1;
          }
          text1 = text1 >= 3 ? 1 : 0;
          exe1 = exe1 >= 5 ? 1 : 0;
          if (sz > 0) h1 = h1 * h1 ~/ sz;
          var h2 = h1 & 0xFFFFFFFF;
          var hi = hits;
          if (h2 > hi) hi = h2;
          h2 = o1ct[0] * sz ~/ 256;
          if (h2 > hi) hi = h2;
          h2 = 0;
          for (var i = 0; i < 256 * on; ++i) {
            if (o1prev[i] == o1[i & 255]) ++h2;
          }
          h2 = h2 * sz ~/ (256 * on);
          if (h2 > hi) hi = h2;
          if (hi > sz) hi = sz;

          var newblock = false;
          if (frags > 0 && fj == 0) {
            final esize = p.size;
            final newsize = sb.size + esize + (esize >> 14) + 4096 + frags * 4;
            if (newsize > blocksize ~/ 4 && redundancy < sb.size ~/ 128) {
              newblock = true;
            }
            if (newblock) {
              var ct = 0;
              for (var i = 0; i < 256 * on; ++i) {
                if (o1prev[i] != 0 && o1prev[i] == o1[i & 255]) ++ct;
              }
              if (ct > on * 2) newblock = false;
            }
            if (newsize >= blocksize) newblock = true;
          }
          if (sb.size + sz + 80 + frags * 4 >= blocksize) newblock = true;
          if (frags < 1) newblock = false;
          if (newblock) flushBlock();
          sb.write(frag, 0, sz);
          ++frags;
          redundancy = (redundancy + hi) & 0xFFFFFFFF;
          exe += exe1 * 4;
          text += text1 * 2;
          if (sz >= minFragment) {
            o1prev.setRange(0, 256 * (on - 1), o1prev, 256);
            o1prev.setRange(256 * (on - 1), 256 * on, o1);
          }
          htptr = ht.add(sha1result, sz);
          fi.update();
        }
        ptrs.add(htptr);
        ++fj;
        completed += sz;
        o1.fillRange(0, 256, 0);
      }

      var sz = 0, hits = 0, c1 = 0, hh = 0;
      // uncaptured copies for the byte loop
      final bb = buf, t1 = o1, fb = frag;
      final maxF = maxFragment, minF = minFragment, lim = limit;

      for (;;) {
        final n = stream.read(bb, 0, bb.length);
        if (n <= 0) break;
        for (var i = 0; i < n; i++) {
          final c = bb[i];
          final hit = ((c ^ t1[c1]) - 1) >>> 63; // 1 if c == o1[c1]
          hh = ((hh + c + 1) * (271828182 + hit * (314159265 - 271828182))) &
              0xFFFFFFFF;
          hits += hit;
          t1[c1] = c;
          c1 = c;
          fb[sz++] = c;
          if (sz >= maxF || (hh < lim && sz >= minF)) {
            fragmentDone(sz, hits);
            sz = hits = c1 = hh = 0;
          }
        }
        cb.setCompleted(completed);
      }
      // zpaq ends every file with the fragment cut by the end, even an
      // empty one
      fragmentDone(sz, hits);
    } finally {
      releaseStream(stream);
    }
    p.ptr = Uint32List.fromList(ptrs);
    p.data = true;
    p.crc = crc.value;
    p.xxhash = xx?.digest();
    p.sha1 = fileSha?.digest();
    cb.setOperationResult(0);
  }
  if (frags > 0) flushBlock();
  cb.setCompleted(completed);

  // ---- fragment tables (h blocks) ----
  final cdatasize = out.position - headerEnd;
  final isb = ZBuffer();
  blocklist.add(ht.length);
  for (var i = 0; i < csize.length; ++i) {
    if (blocklist[i] < blocklist[i + 1]) {
      isb.putLE(csize[i], 4);
      for (var j = blocklist[i]; j < blocklist[i + 1]; ++j) {
        isb.write(ht.sha1Bytes(), 20 * j, 20);
        isb.putLE(ht.usize(j), 4);
      }
      compressBlock(isb, out, '0',
          filename: 'jDC${itos(date, 14)}h${itos(blocklist[i], 10)}',
          comment: 'jDC\x01');
      isb.clear();
    }
  }

  // ---- index (i blocks): deletions, then the new and changed entries ----
  var dtcount = 0;
  final indexTables = LzHashTables();
  void flushIndex() {
    compressBlock(isb, out, '1',
        filename: 'jDC${itos(date)}i${itos(++dtcount, 10)}',
        comment: 'jDC\x01',
        tables: indexTables);
    isb.clear();
  }

  // a file that could not be read keeps its old entry
  for (final p in items) {
    if (p.failed && p.old == null) finalNames.remove(p.name);
  }
  var removed = 0;
  final names = dt.keys.toList()..sort(compareNames);
  for (final name in names) {
    final e = dt[name]!;
    if (!e.isDeleted && !finalNames.contains(name)) {
      isb.putLE(0, 8);
      isb.addAll(utf8.encode(name));
      isb.put(0);
      ++removed;
      if (isb.size > 16000) flushIndex();
    }
  }

  var written = 0;
  items.sort((a, b) => compareNames(a.name, b.name));
  for (final p in items) {
    if (p.failed) continue;
    final a = dt[p.name];
    final isNew = a == null || a.isDeleted;
    final ptr = p.ptr;
    final changed = isNew ||
        a.date != p.date ||
        (a.attr != 0 && a.attr != p.attr) ||
        (!p.isDir && !_ptrEqual(a.ptr, ptr));
    if (!changed) continue;
    ++written;
    isb.putLE(p.date, 8);
    isb.addAll(utf8.encode(p.name));
    isb.put(0);
    final nattr = (p.attr & 255) == 0x75 ? 3 : ((p.attr & 255) == 0x77 ? 5 : 0);
    Uint8List? franz;
    if (!p.isDir) {
      if (p.data && opt.storeHashes) {
        franz = p.xxhash != null
            ? FranzInfo.encodeXxhash64(p.xxhash!, p.crc, isNew)
            : FranzInfo.encodeSha1(p.sha1!, p.crc);
      } else if (!p.data && p.old?.franz != null) {
        // same content (a rename or new attributes): same hash
        franz = _reencode(p.old!.franz!, isNew);
      }
    }
    if (franz != null) {
      isb.putLE(8 + franz.length, 4);
      isb.putLE(p.attr, nattr);
      isb.putLE(0, 8 - nattr);
      isb.write(franz, 0, franz.length);
    } else {
      isb.putLE(nattr, 4);
      isb.putLE(p.attr, nattr);
    }
    isb.putLE(ptr.length, 4);
    for (final j in ptr) {
      isb.putLE(j, 4);
    }
    if (isb.size > 16000) flushIndex();
  }
  if (isb.size > 0) flushIndex();

  // ---- commit ----
  final archiveEnd = out.position;
  if (written + removed == 0 && csize.isEmpty && idx.versions.isNotEmpty) {
    // nothing changed: no new version
    out.flush();
    outStream.truncate(headerPos);
    outStream.position = headerPos;
    return;
  }
  out.seek(headerPos);
  _writeHeader(out, date, cdatasize, htsize);
  out.flush();
  outStream.position = archiveEnd;
  outStream.flush();
}

Uint8List? _reencode(FranzInfo f, bool isNew) {
  if (f.hashType == 'XXHASH64' && f.hash.length == 16) {
    final v = (int.parse(f.hash.substring(0, 8), radix: 16) << 32) |
        int.parse(f.hash.substring(8), radix: 16);
    return FranzInfo.encodeXxhash64(
        v, int.tryParse(f.crc32, radix: 16) ?? 0, isNew);
  }
  if (f.hashType != 'SHA-1' || f.hash.length != 40) return null;
  final b = Uint8List(20);
  for (var i = 0; i < 20; ++i) {
    b[i] = int.parse(f.hash.substring(2 * i, 2 * i + 2), radix: 16);
  }
  return FranzInfo.encodeSha1(b, int.tryParse(f.crc32, radix: 16) ?? 0);
}
