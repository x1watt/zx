// A least recently used cache with a byte budget (the page cache of
// decoded pages, the cache of decoded page blocks).

import 'dart:collection';

class LruCache<V extends Object> {
  /// The budget in bytes (0 keeps nothing).
  int budget;
  final int Function(V v) sizeOf;
  final LinkedHashMap<int, V> _map = LinkedHashMap<int, V>();
  int _bytes = 0;

  /// Hits and misses (for tests and statistics).
  int hits = 0;
  int misses = 0;

  LruCache(this.budget, this.sizeOf);

  int get bytes => _bytes;
  int get length => _map.length;

  V? get(int key) {
    final v = _map.remove(key);
    if (v == null) {
      misses++;
      return null;
    }
    hits++;
    _map[key] = v;
    return v;
  }

  void put(int key, V v) {
    final old = _map.remove(key);
    if (old != null) _bytes -= sizeOf(old);
    final s = sizeOf(v);
    if (s > budget) return;
    _map[key] = v;
    _bytes += s;
    while (_bytes > budget && _map.isNotEmpty) {
      final k = _map.keys.first;
      _bytes -= sizeOf(_map.remove(k) as V);
    }
  }

  void clear() {
    _map.clear();
    _bytes = 0;
  }
}
