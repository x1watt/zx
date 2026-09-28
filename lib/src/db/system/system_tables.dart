// The system tables every .zx archive exposes (docs/zxdb-design.md, 1.1):
// read-only virtual tables over the archive's Index, no copy.
//
//   zx_files         path, kind, size, packed, mtime, ctime, mode, sha256,
//                    tlsh, since_generation, method, encrypted
//   zx_generations   number, time, comment, added, deleted, packed
//   zx_file_history  path, generation, time, sha256, size, event
//
// All honour AS OF (a generation number, a date or a time). Plans:
//   zx_files: sha256 = ? by the sorted SHA-256 table (binary search);
//             path = ? by a path map; path ranges, GLOB 'p*' and LIKE 'p%'
//             (when p has no letters) by the path-sorted order, which also
//             gives ORDER BY path; since_generation compared on the fly.
//   zx_generations: number = ? and ranges.
//   zx_file_history: path = ? walks the generations back and skips the
//             ones in which the file stayed the same (attribute 0x76, as
//             the timeline does); generation = ? compares one generation
//             with the one before; otherwise every generation in turn.

import 'dart:typed_data';

import '../../format/zx/zx_format.dart';
import 'archive_view.dart';
import 'sys_vtab.dart';

// ---------------------------------------------------------------------------
// zx_files

class ZxFilesTable extends SysVTable {
  final ZxArchiveView archive;
  ZxFilesTable(this.archive);

  static const cPath = 0,
      cKind = 1,
      cSize = 2,
      cPacked = 3,
      cMtime = 4,
      cCtime = 5,
      cMode = 6,
      cSha256 = 7,
      cTlsh = 8,
      cSince = 9,
      cMethod = 10,
      cEncrypted = 11;

  static const _columns = [
    SysColumn('path', 'TEXT'),
    SysColumn('kind', 'TEXT'),
    SysColumn('size', 'INTEGER'),
    SysColumn('packed', 'INTEGER'),
    SysColumn('mtime', 'DATETIME'),
    SysColumn('ctime', 'DATETIME'),
    SysColumn('mode', 'INTEGER'),
    SysColumn('sha256', 'BLOB'),
    SysColumn('tlsh', 'TEXT'),
    SysColumn('since_generation', 'INTEGER'),
    SysColumn('method', 'TEXT'),
    SysColumn('encrypted', 'INTEGER'),
  ];

  @override
  String get name => 'zx_files';
  @override
  List<SysColumn> get columns => _columns;

  // idxNum: 1 sha256 =, 2 path =, 3 path range/prefix, 0 full scan.
  // idxStr: space separated argument roles in argv order:
  //   sha, path, lo>=, lo>, hi<=, hi<, glob, like, since=, since>, since>=,
  //   since<, since<=, sorted (full scan in path order)
  @override
  void bestIndex(SysIndexInfo info) {
    final cs = info.constraints;
    final roles = <String>[];
    int? find(int col, SysOp op) {
      for (var i = 0; i < cs.length; i++) {
        if (cs[i].usable && cs[i].column == col && cs[i].op == op) return i;
      }
      return null;
    }

    void use(int i, String role, {bool omit = true}) {
      info.use(i, omit: omit);
      roles.add(role);
    }

    final sha = find(cSha256, SysOp.eq);
    final path = find(cPath, SysOp.eq);
    if (sha != null) {
      info.idxNum = 1;
      use(sha, 'sha');
      info.estimatedCost = 5;
      info.estimatedRows = 1;
    } else if (path != null) {
      info.idxNum = 2;
      use(path, 'path');
      info.estimatedCost = 2;
      info.estimatedRows = 1;
    } else {
      var ranged = false;
      for (var i = 0; i < cs.length; i++) {
        final c = cs[i];
        if (!c.usable || c.column != cPath) continue;
        switch (c.op) {
          case SysOp.ge:
            use(i, 'lo>=');
          case SysOp.gt:
            use(i, 'lo>');
          case SysOp.le:
            use(i, 'hi<=');
          case SysOp.lt:
            use(i, 'hi<');
          case SysOp.glob:
            use(i, 'glob', omit: false);
          case SysOp.like:
            use(i, 'like', omit: false);
          default:
            continue;
        }
        ranged = true;
      }
      if (ranged) {
        info.idxNum = 3;
        info.estimatedCost = 1000;
        info.estimatedRows = 1000;
      } else {
        info.idxNum = 0;
        info.estimatedCost = 100000;
        info.estimatedRows = 100000;
      }
    }
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      if (!c.usable || c.column != cSince || info.argvIndex[i] != 0) continue;
      final role = switch (c.op) {
        SysOp.eq => 'since=',
        SysOp.gt => 'since>',
        SysOp.ge => 'since>=',
        SysOp.lt => 'since<',
        SysOp.le => 'since<=',
        _ => null,
      };
      if (role != null) use(i, role);
    }
    final ob = info.orderBy;
    if (ob.length == 1 && ob[0].column == cPath && !ob[0].desc) {
      if (info.idxNum == 0) roles.add('sorted');
      info.orderByConsumed = true;
    }
    info.idxStr = roles.join(' ');
  }

  @override
  SysCursor open(SysIndexInfo info, List<Object?> args, {SysAsOf? asOf}) {
    final v = archive.at(asOf);
    final roles = info.idxStr.isEmpty ? const <String>[] : info.idxStr.split(' ');
    Iterable<int> rows;
    var sinceChecks = <(String, int)>[];
    String? lo, hi;
    var loIn = true, hiIn = false;
    var none = false;
    for (var k = 0; k < roles.length; k++) {
      if (roles[k] == 'sorted') continue;
      final a = k < args.length ? args[k] : null;
      switch (roles[k]) {
        case 'lo>=' || 'lo>':
          if (a is! String) {
            none = true;
            continue;
          }
          final inc = roles[k] == 'lo>=';
          if (lo == null || a.compareTo(lo) > 0 || (a == lo && !inc)) {
            lo = a;
            loIn = inc;
          }
        case 'hi<=' || 'hi<':
          if (a is! String) {
            none = true;
            continue;
          }
          final inc = roles[k] == 'hi<=';
          if (hi == null || a.compareTo(hi) < 0 || (a == hi && !inc)) {
            hi = a;
            hiIn = inc;
          }
        case 'glob' || 'like':
          if (a is! String) {
            none = true;
            continue;
          }
          final p = roles[k] == 'glob'
              ? sysGlobPrefix(a)
              : _caseless(sysLikePrefix(a));
          if (p != null && p.isNotEmpty) {
            if (lo == null || p.compareTo(lo) > 0) {
              lo = p;
              loIn = true;
            }
            final end = _prefixEnd(p);
            if (end != null && (hi == null || end.compareTo(hi) < 0)) {
              hi = end;
              hiIn = false;
            }
          }
        default:
          if (roles[k].startsWith('since')) {
            if (a is! int) {
              none = true;
              continue;
            }
            sinceChecks.add((roles[k].substring(5), a));
          }
      }
    }
    if (none) return SysListCursor(const []);
    switch (info.idxNum) {
      case 1:
        final a = args.isEmpty ? null : args[0];
        rows = a is Uint8List ? v.findBySha256(a) : const <int>[];
        if (info.orderByConsumed) {
          final l = rows.toList()
            ..sort((x, y) => v.entries[x].path.compareTo(v.entries[y].path));
          rows = l;
        }
      case 2:
        final a = args.isEmpty ? null : args[0];
        final i = a is String ? v.entryOf(a) : null;
        rows = i == null ? const <int>[] : [i];
      case 3:
        rows = v.pathRange(lo, hi, loInclusive: loIn, hiInclusive: hiIn);
      default:
        rows = roles.contains('sorted')
            ? v.sortedByPath
            : Iterable<int>.generate(v.entries.length);
    }
    if (sinceChecks.isNotEmpty) {
      final gen = v.generation.number;
      rows = rows.where((i) {
        final s = v.entries[i].since ?? gen;
        for (final (op, x) in sinceChecks) {
          final ok = switch (op) {
            '=' => s == x,
            '>' => s > x,
            '>=' => s >= x,
            '<' => s < x,
            _ => s <= x,
          };
          if (!ok) return false;
        }
        return true;
      });
    }
    return _FilesCursor(v, rows.iterator, archive.encrypted);
  }

  // LIKE is case insensitive: a prefix is only usable when it has no
  // letters (then both cases are the same bytes).
  static String? _caseless(String? p) {
    if (p == null) return null;
    if (p.toLowerCase() != p.toUpperCase()) return null;
    return p;
  }

  static String? _prefixEnd(String p) {
    final cu = p.codeUnits.toList();
    while (cu.isNotEmpty) {
      if (cu.last < 0xFFFF) {
        cu[cu.length - 1]++;
        return String.fromCharCodes(cu);
      }
      cu.removeLast();
    }
    return null;
  }
}

class _FilesCursor extends SysCursor {
  final ZxIndexView v;
  final Iterator<int> it;
  final bool encrypted;
  int _i = -1;
  _FilesCursor(this.v, this.it, this.encrypted);

  @override
  bool moveNext() {
    if (!it.moveNext()) return false;
    _i = it.current;
    return true;
  }

  @override
  int get rowid => _i;

  @override
  Object? column(int c) {
    final e = v.entries[_i];
    switch (c) {
      case ZxFilesTable.cPath:
        return e.path;
      case ZxFilesTable.cKind:
        return zxKindName(e.kind);
      case ZxFilesTable.cSize:
        return e.size;
      case ZxFilesTable.cPacked:
        return v.packedOf(_i);
      case ZxFilesTable.cMtime:
        return e.mTime;
      case ZxFilesTable.cCtime:
        return e.cTime;
      case ZxFilesTable.cMode:
        return e.mode;
      case ZxFilesTable.cSha256:
        return e.sha256;
      case ZxFilesTable.cTlsh:
        return e.tlsh;
      case ZxFilesTable.cSince:
        return e.since ?? v.generation.number;
      case ZxFilesTable.cMethod:
        return v.methodOf(_i);
      case ZxFilesTable.cEncrypted:
        return encrypted && e.extents.isNotEmpty ? 1 : 0;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// zx_generations

class ZxGenerationsTable extends SysVTable {
  final ZxArchiveView archive;
  ZxGenerationsTable(this.archive);

  static const _columns = [
    SysColumn('number', 'INTEGER'),
    SysColumn('time', 'DATETIME'),
    SysColumn('comment', 'TEXT'),
    SysColumn('added', 'INTEGER'),
    SysColumn('deleted', 'INTEGER'),
    SysColumn('packed', 'INTEGER'),
  ];

  @override
  String get name => 'zx_generations';
  @override
  List<SysColumn> get columns => _columns;

  @override
  void bestIndex(SysIndexInfo info) {
    final roles = <String>[];
    for (var i = 0; i < info.constraints.length; i++) {
      final c = info.constraints[i];
      if (!c.usable || c.column != 0) continue;
      final r = switch (c.op) {
        SysOp.eq => '=',
        SysOp.gt => '>',
        SysOp.ge => '>=',
        SysOp.lt => '<',
        SysOp.le => '<=',
        _ => null,
      };
      if (r == null) continue;
      info.use(i);
      roles.add(r);
    }
    info.idxStr = roles.join(' ');
    info.estimatedCost = roles.contains('=') ? 1 : 100;
    final ob = info.orderBy;
    info.orderByConsumed = ob.length == 1 && ob[0].column == 0;
    info.idxNum = info.orderByConsumed && ob[0].desc ? 1 : 0;
  }

  @override
  SysCursor open(SysIndexInfo info, List<Object?> args, {SysAsOf? asOf}) {
    final roles = info.idxStr.isEmpty ? const <String>[] : info.idxStr.split(' ');
    var gens = archive.generationsUpTo(asOf);
    for (var k = 0; k < roles.length; k++) {
      final a = args[k];
      if (a is! int) return SysListCursor(const []);
      gens = [
        for (final g in gens)
          if (switch (roles[k]) {
            '=' => g.number == a,
            '>' => g.number > a,
            '>=' => g.number >= a,
            '<' => g.number < a,
            _ => g.number <= a,
          })
            g
      ];
    }
    if (info.idxNum == 1) gens = gens.reversed.toList();
    return SysListCursor([
      for (final g in gens)
        [g.number, g.time, g.comment, g.added, g.deleted, g.packed]
    ]);
  }
}

// ---------------------------------------------------------------------------
// zx_file_history

/// One event of zx_file_history.
class ZxFileEvent {
  final String path;
  final int generation;
  final int time;
  final Uint8List? sha256;
  final int size;

  /// 'added', 'changed' or 'deleted'.
  final String event;
  const ZxFileEvent(
      this.path, this.generation, this.time, this.sha256, this.size, this.event);

  List<Object?> get row => [path, generation, time, sha256, size, event];

  @override
  String toString() => '$event $path @$generation';
}

bool _sameBytes(Uint8List a, Uint8List b) => sysCompareBytes(a, b) == 0;

/// Whether [b] (in generation [gen]) is new content compared with [a].
bool _changed(ZxEntry a, ZxEntry b, int gen) {
  final sa = a.sha256, sb = b.sha256;
  if (sa != null && sb != null) return !_sameBytes(sa, sb);
  if (a.size != b.size || a.kind != b.kind) return true;
  return b.since == gen && a.since != gen;
}

/// The events of generation [g] (compared with [prev], null for the first
/// generation), in path order.
List<ZxFileEvent> zxGenerationEvents(ZxIndexView? prev, ZxIndexView cur) {
  final g = cur.generation;
  final out = <ZxFileEvent>[];
  for (final i in cur.sortedByPath) {
    final e = cur.entries[i];
    if (prev == null) {
      out.add(ZxFileEvent(e.path, g.number, g.time, e.sha256, e.size, 'added'));
      continue;
    }
    final pi = prev.entryOf(e.path);
    if (pi == null) {
      out.add(ZxFileEvent(e.path, g.number, g.time, e.sha256, e.size, 'added'));
      continue;
    }
    // kept entries carry their since generation forward: unchanged
    final s = e.since;
    if (s != null && s < g.number) continue;
    if (_changed(prev.entries[pi], e, g.number)) {
      out.add(
          ZxFileEvent(e.path, g.number, g.time, e.sha256, e.size, 'changed'));
    }
  }
  if (prev != null) {
    for (final i in prev.sortedByPath) {
      final e = prev.entries[i];
      if (cur.entryOf(e.path) == null) {
        out.add(
            ZxFileEvent(e.path, g.number, g.time, e.sha256, e.size, 'deleted'));
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
  }
  return out;
}

/// The events of one [path] up to [asOf], oldest first. Walks back from
/// the last generation and skips the generations in which the content
/// stayed the same (attribute 0x76).
List<ZxFileEvent> zxPathHistory(ZxArchiveView a, String path,
    {SysAsOf? asOf}) {
  final gens = a.generationsUpTo(asOf);
  final pos = {for (var k = 0; k < gens.length; k++) gens[k].number: k};
  final out = <ZxFileEvent>[];
  ZxEntry? entryAt(int k) {
    final v = a.indexOf(gens[k]);
    final i = v.entryOf(path);
    return i == null ? null : v.entries[i];
  }

  // the state of generation i + 1 (null: absent or past the end)
  ZxEntry? next;
  var i = gens.length - 1;
  while (i >= 0) {
    final e = entryAt(i);
    if (e == null) {
      next = null;
      i--;
      continue;
    }
    var s = pos[e.since ?? gens[i].number] ?? i;
    if (s > i) s = i;
    if (i + 1 < gens.length && next == null) {
      final d = gens[i + 1];
      out.add(ZxFileEvent(path, d.number, d.time, e.sha256, e.size, 'deleted'));
    }
    final g = gens[s];
    if (s == 0) {
      out.add(ZxFileEvent(path, g.number, g.time, e.sha256, e.size, 'added'));
      break;
    }
    final pe = entryAt(s - 1);
    if (pe == null) {
      out.add(ZxFileEvent(path, g.number, g.time, e.sha256, e.size, 'added'));
    } else if (_changed(pe, e, g.number)) {
      out.add(ZxFileEvent(path, g.number, g.time, e.sha256, e.size, 'changed'));
    }
    next = e;
    i = s - 1;
  }
  return out.reversed.toList();
}

class ZxFileHistoryTable extends SysVTable {
  final ZxArchiveView archive;
  ZxFileHistoryTable(this.archive);

  static const _columns = [
    SysColumn('path', 'TEXT'),
    SysColumn('generation', 'INTEGER'),
    SysColumn('time', 'DATETIME'),
    SysColumn('sha256', 'BLOB'),
    SysColumn('size', 'INTEGER'),
    SysColumn('event', 'TEXT'),
  ];

  @override
  String get name => 'zx_file_history';
  @override
  List<SysColumn> get columns => _columns;

  // idxNum 1: path =; idxStr: roles of the args (path, g=, g>, g>=, g<, g<=)
  @override
  void bestIndex(SysIndexInfo info) {
    final roles = <String>[];
    final cs = info.constraints;
    for (var i = 0; i < cs.length; i++) {
      final c = cs[i];
      if (!c.usable) continue;
      if (c.column == 0 && c.op == SysOp.eq && !roles.contains('path')) {
        info.use(i);
        roles.add('path');
        info.idxNum = 1;
      } else if (c.column == 1) {
        final r = switch (c.op) {
          SysOp.eq => 'g=',
          SysOp.gt => 'g>',
          SysOp.ge => 'g>=',
          SysOp.lt => 'g<',
          SysOp.le => 'g<=',
          _ => null,
        };
        if (r == null) continue;
        info.use(i);
        roles.add(r);
      }
    }
    info.idxStr = roles.join(' ');
    info.estimatedCost = info.idxNum == 1
        ? 50
        : roles.contains('g=')
            ? 500
            : 100000;
  }

  @override
  SysCursor open(SysIndexInfo info, List<Object?> args, {SysAsOf? asOf}) {
    final roles = info.idxStr.isEmpty ? const <String>[] : info.idxStr.split(' ');
    String? path;
    var lo = 0, hi = 1 << 62;
    for (var k = 0; k < roles.length; k++) {
      final a = args[k];
      if (roles[k] == 'path') {
        if (a is! String) return SysListCursor(const []);
        path = a;
        continue;
      }
      if (a is! int) return SysListCursor(const []);
      switch (roles[k]) {
        case 'g=':
          if (a > lo) lo = a;
          if (a < hi) hi = a;
        case 'g>':
          if (a + 1 > lo) lo = a + 1;
        case 'g>=':
          if (a > lo) lo = a;
        case 'g<':
          if (a - 1 < hi) hi = a - 1;
        case 'g<=':
          if (a < hi) hi = a;
      }
    }
    final List<ZxFileEvent> events;
    if (path != null) {
      events = [
        for (final e in zxPathHistory(archive, path, asOf: asOf))
          if (e.generation >= lo && e.generation <= hi) e
      ];
    } else {
      final gens = archive.generationsUpTo(asOf);
      final rows = <ZxFileEvent>[];
      // a lazy cursor would be better for huge histories; generations are
      // decoded one at a time and the events of each are small
      for (var k = 0; k < gens.length; k++) {
        final g = gens[k];
        if (g.number < lo || g.number > hi) continue;
        final prev = k == 0 ? null : archive.indexOf(gens[k - 1]);
        rows.addAll(zxGenerationEvents(prev, archive.indexOf(g)));
      }
      events = rows;
    }
    return SysListCursor([for (final e in events) e.row]);
  }
}
