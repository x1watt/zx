// The storage contract of zxdb (docs/zxdb-design.md). The SQL engine, the
// KV stores, the time series and the system tables are written against
// these interfaces; lib/src/db/engine/ implements them inside a .zx
// archive, and lib/src/db/memory_store.dart implements them in memory for
// tests and for the SQL engine's own unit tests.
//
// Keys and values are byte strings. Keys compare as unsigned bytes
// (memcmp order, shorter first on a common prefix). Encodings of typed
// values into order-preserving keys live in lib/src/db/keycodec.dart.

import 'dart:typed_data';

/// The longest key a tree accepts, in bytes. Longer keys throw
/// ZxDbException(constraint). (A B+tree page must hold at least a few
/// keys; SQL index keys that could be longer need a prefix plus a hash.)
const int zxMaxKeyLength = 1024;

/// The key order of every tree: unsigned bytes, a shorter key first on a
/// common prefix (memcmp order). Returns <0, 0 or >0.
int zxCompareKeys(Uint8List a, Uint8List b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final d = a[i] - b[i];
    if (d != 0) return d;
  }
  return a.length - b.length;
}

/// Errors of the database layer.
class ZxDbException implements Exception {
  final String message;
  final ZxDbError kind;
  const ZxDbException(this.message, [this.kind = ZxDbError.generic]);
  @override
  String toString() => 'ZxDbException(${kind.name}): $message';
}

enum ZxDbError {
  generic,
  notFound,
  constraint,
  busy, // another writer holds the lock
  readOnly,
  corrupt,
  syntax, // SQL
  unsupported,
}

/// Per-tree storage options (from `WITH (...)` or ALTER ... SET).
class TreeOptions {
  /// 'store', 'fast', 'balanced', 'max', 'ultra', or an explicit .zx
  /// chain string such as 'zcm:level=7:mem=1g'. Null: archive default
  /// ('max').
  final String? compression;

  /// Logical page size in bytes (4096..65536, power of two). Null: default.
  final int? pageSize;

  const TreeOptions({this.compression, this.pageSize});
}

/// An ordered map from keys to values: the one primitive every zxdb
/// structure (tables, indexes, KV stores, catalog, time series metadata)
/// is built on. Implementations are copy-on-write B+trees.
abstract class ZxTree {
  String get name;
  TreeOptions get options;

  Uint8List? get(Uint8List key);

  /// Cursor over keys in [from, to) (null bounds are open), ascending or
  /// descending.
  ZxCursor scan({Uint8List? from, Uint8List? to, bool reverse = false});

  /// Number of entries (maintained exactly).
  int get length;
}

/// A tree inside a write transaction.
/// [put] keeps its own copies of the key and the value, so callers may
/// reuse their buffers. Arrays returned by [get] and cursors must not be
/// modified.
abstract class ZxWritableTree implements ZxTree {
  void put(Uint8List key, Uint8List value);

  /// Returns true when the key existed.
  bool delete(Uint8List key);

  /// Deletes every key in [from, to); returns the count.
  int deleteRange({Uint8List? from, Uint8List? to});
}

/// A cursor starts before its first entry: call [moveNext] first.
///
/// A cursor of a tree inside the write transaction stays valid while the
/// same transaction writes to that tree: each [moveNext] continues after
/// the last key it returned (before it, when reverse), in the tree as it
/// is at that call, so it sees keys inserted ahead of it and skips keys
/// deleted ahead of it. A cursor of a snapshot sees that snapshot only.
/// [key] and [value] are only valid after a [moveNext] that returned
/// true, and the arrays must not be modified.
abstract class ZxCursor {
  /// Advances; false at the end.
  bool moveNext();
  Uint8List get key;
  Uint8List get value;
  void close();
}

/// A consistent read view of the whole database at one generation.
abstract class ZxSnapshot {
  /// The archive generation this snapshot reads.
  int get generation;

  /// Commit time of that generation (ns since epoch, UTC).
  int get timeNs;

  List<String> get treeNames;

  /// Null when the tree does not exist at this generation.
  ZxTree? tree(String name);

  void close();
}

/// The single write transaction. Changes become visible to new snapshots
/// only after [commit], which appends one archive generation.
///
/// As a snapshot, it reads its own uncommitted changes; [generation] and
/// [timeNs] are those of the generation it started from. After [commit]
/// or [rollback] the transaction is closed, and using it (or a tree or
/// cursor of it) throws StateError. [createTree] throws
/// ZxDbException(constraint) when the tree exists; [dropTree] and
/// [setTreeOptions] throw ZxDbException(notFound) when it does not.
abstract class ZxWriteTxn implements ZxSnapshot {
  ZxWritableTree createTree(String name, [TreeOptions options]);
  void dropTree(String name);
  void setTreeOptions(String name, TreeOptions options);

  @override
  ZxWritableTree? tree(String name);

  /// Appends a generation (with [comment]); returns its number. A
  /// transaction that wrote nothing appends nothing and returns the
  /// generation it started from.
  int commit({String? comment});
  void rollback();
}

/// A database store: opens snapshots and the write transaction.
abstract class ZxStore {
  /// Latest committed state, or an older generation (number), or the last
  /// generation at or before [atTimeNs]. Throws ZxDbException(notFound)
  /// when there is no such generation. A store without any generation yet
  /// gives an empty snapshot of generation 0 for the latest state.
  ZxSnapshot snapshot({int? generation, int? atTimeNs});

  /// Starts the write transaction; throws ZxDbException(busy) when another
  /// writer (process or isolate) holds the lock and [waitMs] expires.
  ZxWriteTxn begin({int waitMs = 5000});

  /// Generations with times, oldest first.
  List<({int generation, int timeNs, String? comment})> get generations;

  void close();
}
