// Key-value stores of zxdb (docs/zxdb-design.md 2.2): an ordered map of
// byte strings in the tree "kv:<name>", with a Dart API that bypasses
// SQL: get, put, delete, scans by prefix or range, batches, watch (a
// stream of the changes committed by this process) and time to live.
//
// Stored values (what SQL and other readers of the tree see) carry a
// one byte header: 0 then the value, or 1, the expiry as a u64 (ms since
// 1970-01-01 UTC, little endian), then the value. [zxKvDecode] reads
// them; an expired value is invisible and removed at fold and vacuum.
//
// The settings of the stores (default TTL, whether a key ever got a TTL)
// are in the tree "zx$kv" (key the name, value vint version 1, vint ttl
// ms or 0, vint flags).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'zxdb.dart';

/// The tree of a KV store.
String zxKvTreeName(String store) => 'kv:$store';

/// The tree of the settings of the KV stores.
const String zxKvMetaTree = r'zx$kv';

/// The stored form of [value] expiring at [expiresAtMs] (null: never).
Uint8List zxKvEncode(Uint8List value, int? expiresAtMs) {
  if (expiresAtMs == null) {
    final out = Uint8List(value.length + 1);
    out.setRange(1, out.length, value);
    return out;
  }
  final out = Uint8List(value.length + 9);
  out[0] = 1;
  var e = expiresAtMs;
  for (var i = 1; i <= 8; i++) {
    out[i] = e & 0xFF;
    e >>= 8;
  }
  out.setRange(9, out.length, value);
  return out;
}

/// The value and expiry of a stored value (null when it is not one).
({Uint8List value, int? expiresAtMs})? zxKvDecode(Uint8List stored) {
  if (stored.isEmpty) return null;
  if (stored[0] == 0) {
    return (value: Uint8List.sublistView(stored, 1), expiresAtMs: null);
  }
  if (stored[0] != 1 || stored.length < 9) return null;
  var e = 0;
  for (var i = 8; i >= 1; i--) {
    e = (e << 8) | stored[i];
  }
  return (value: Uint8List.sublistView(stored, 9), expiresAtMs: e);
}

/// The value of [stored] when it is live at [nowMs], else null.
Uint8List? zxKvLive(Uint8List stored, int nowMs) {
  final d = zxKvDecode(stored);
  if (d == null) return null;
  final e = d.expiresAtMs;
  if (e != null && e <= nowMs) return null;
  return d.value;
}

/// The first key after every key that starts with [prefix] (null: none).
Uint8List? zxPrefixEnd(Uint8List prefix) {
  var n = prefix.length;
  while (n > 0 && prefix[n - 1] == 0xFF) {
    n--;
  }
  if (n == 0) return null;
  final out = Uint8List.fromList(Uint8List.sublistView(prefix, 0, n));
  out[n - 1]++;
  return out;
}

bool _startsWith(Uint8List k, Uint8List p) {
  if (k.length < p.length) return false;
  for (var i = 0; i < p.length; i++) {
    if (k[i] != p[i]) return false;
  }
  return true;
}

Uint8List _utf8(String s) => Uint8List.fromList(utf8.encode(s));

/// One entry of a scan.
class ZxKvEntry {
  final Uint8List key;
  final Uint8List value;

  /// Expiry, ms since 1970-01-01 UTC (null: never).
  final int? expiresAtMs;
  const ZxKvEntry(this.key, this.value, this.expiresAtMs);

  String get keyString => utf8.decode(key);
  String get valueString => utf8.decode(value);
}

/// One change of a KV store, as [ZxKvStore.watch] gives it.
class ZxKvChange {
  final String store;
  final Uint8List key;

  /// The new value; null for a deletion.
  final Uint8List? value;

  /// The generation that committed it.
  final int generation;
  const ZxKvChange(this.store, this.key, this.value, this.generation);

  bool get deleted => value == null;
}

/// The settings of a KV store.
class ZxKvSettings {
  /// Default time to live of new values, ms (null: none).
  final int? ttlMs;

  /// Some value got a time to live (a purge is worth it).
  final bool mayExpire;
  const ZxKvSettings(this.ttlMs, this.mayExpire);

  Uint8List encode() {
    final b = BytesBuilder();
    void vint(int v) {
      while (v >= 0x80) {
        b.addByte((v & 0x7F) | 0x80);
        v >>= 7;
      }
      b.addByte(v);
    }

    vint(1);
    vint(ttlMs ?? 0);
    vint(mayExpire ? 1 : 0);
    return b.toBytes();
  }

  static ZxKvSettings decode(Uint8List b) {
    var p = 0;
    int vint() {
      var v = 0, s = 0;
      for (;;) {
        if (p >= b.length || s > 63) {
          throw const ZxDbException('damaged KV settings', ZxDbError.corrupt);
        }
        final c = b[p++];
        v |= (c & 0x7F) << s;
        if (c < 0x80) return v;
        s += 7;
      }
    }

    if (vint() != 1) {
      throw const ZxDbException('unsupported KV settings', ZxDbError.unsupported);
    }
    final ttl = vint();
    final flags = vint();
    return ZxKvSettings(ttl == 0 ? null : ttl, (flags & 1) != 0);
  }
}

/// Writes of a batch, applied in one transaction by [ZxKvStore.batch].
class ZxKvBatch {
  final List<(Uint8List, Uint8List?, Duration?)> ops = [];

  void put(Uint8List key, Uint8List value, {Duration? ttl}) =>
      ops.add((Uint8List.fromList(key), Uint8List.fromList(value), ttl));
  void putString(String key, String value, {Duration? ttl}) =>
      ops.add((_utf8(key), _utf8(value), ttl));
  void delete(Uint8List key) => ops.add((Uint8List.fromList(key), null, null));
  void deleteString(String key) => ops.add((_utf8(key), null, null));
}

/// A key-value store of a [ZxDatabase]. Obtained from [ZxDatabase.kv] (the
/// current state, writable) or with a generation or a time (read only).
class ZxKvStore {
  final ZxDatabase db;
  final String name;

  /// Read at this snapshot (a past generation), read only.
  final ZxSnapshot? at;

  ZxKvStore(this.db, this.name, {this.at});

  String get treeName => zxKvTreeName(name);

  bool get readOnly => at != null || db.readOnly;

  ZxKvSettings get settings => db.kvSettings(name, at: at);

  ZxTree _tree() {
    final t = (at ?? db.readSnapshot()).tree(treeName);
    if (t == null) {
      throw ZxDbException('no KV store "$name"', ZxDbError.notFound);
    }
    return t;
  }

  void _checkWrite() {
    if (at != null) {
      throw const ZxDbException(
          'a KV store of a past generation is read only', ZxDbError.readOnly);
    }
  }

  /// The value of [key], or null (absent or expired).
  Uint8List? get(Uint8List key) {
    final v = _tree().get(key);
    return v == null ? null : zxKvLive(v, db.nowMs());
  }

  String? getString(String key) {
    final v = get(_utf8(key));
    return v == null ? null : utf8.decode(v);
  }

  /// Stores [value] under [key]; [ttl] overrides the store's default.
  void put(Uint8List key, Uint8List value, {Duration? ttl}) {
    _checkWrite();
    db.kvApply(name, [(key, value, ttl)]);
  }

  void putString(String key, String value, {Duration? ttl}) =>
      put(_utf8(key), _utf8(value), ttl: ttl);

  /// Removes [key]; true when it held a live value.
  bool delete(Uint8List key) {
    _checkWrite();
    final had = get(key) != null;
    db.kvApply(name, [(key, null, null)]);
    return had;
  }

  bool deleteString(String key) => delete(_utf8(key));

  /// Applies the writes of [build] in one transaction (one generation, or
  /// the pending one with group commit).
  void batch(void Function(ZxKvBatch b) build) {
    _checkWrite();
    final b = ZxKvBatch();
    build(b);
    if (b.ops.isNotEmpty) db.kvApply(name, b.ops);
  }

  /// The live entries with [prefix] or in [from, to), in key order (or
  /// reverse), at most [limit]. Lazy: the entries are read as the
  /// iteration goes, from the state when it started.
  Iterable<ZxKvEntry> scan(
      {Uint8List? prefix,
      Uint8List? from,
      Uint8List? to,
      bool reverse = false,
      int? limit}) sync* {
    var lo = from, hi = to;
    if (prefix != null && prefix.isNotEmpty) {
      if (lo == null || zxCompareKeys(lo, prefix) < 0) lo = prefix;
      final pe = zxPrefixEnd(prefix);
      if (pe != null && (hi == null || zxCompareKeys(hi, pe) > 0)) hi = pe;
    }
    final now = db.nowMs();
    final c = _tree().scan(from: lo, to: hi, reverse: reverse);
    var n = 0;
    try {
      while ((limit == null || n < limit) && c.moveNext()) {
        final d = zxKvDecode(c.value);
        if (d == null) continue;
        final e = d.expiresAtMs;
        if (e != null && e <= now) continue;
        n++;
        yield ZxKvEntry(c.key, d.value, e);
      }
    } finally {
      c.close();
    }
  }

  /// The changes of this store committed by this process from now on,
  /// for keys with [prefix].
  Stream<ZxKvChange> watch({Uint8List? prefix}) => db.changes.where((c) =>
      c.store == name && (prefix == null || _startsWith(c.key, prefix)));

  /// Entries stored (expired ones not purged yet included).
  int get length => _tree().length;

  /// Removes the expired values now; returns how many.
  int purgeExpired() {
    _checkWrite();
    return db.kvPurge(name);
  }
}
