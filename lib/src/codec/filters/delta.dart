// Delta filter: port of C/Delta.c and CPP/7zip/Compress/DeltaFilter.cpp.
// The 7z coder property is one byte: distance - 1.

import 'dart:typed_data';

import 'filter_coder.dart';

/// DELTA_STATE_SIZE
const int kDeltaStateSize = 256;

// Delta_Init
void deltaInit(Uint8List state) {
  for (var i = 0; i < kDeltaStateSize; i++) {
    state[i] = 0;
  }
}

// Delta_Encode
void deltaEncode(
    Uint8List state, int delta, Uint8List data, int off, int size) {
  if (size == 0) return;
  final temp = Uint8List(kDeltaStateSize);
  for (var i = 0; i < delta; i++) {
    temp[i] = state[i];
  }

  if (size <= delta) {
    var i = 0;
    var p = off;
    do {
      final b = data[p];
      data[p++] = b - temp[i];
      temp[i] = b;
    } while (++i != size);
    var k = 0;
    do {
      if (i == delta) i = 0;
      state[k] = temp[i++];
    } while (++k != delta);
    return;
  }

  var p = off + size - delta;
  for (var i = 0; i < delta; i++) {
    state[i] = data[p++];
  }
  final lim = off + delta;
  // Walk back from the end: each byte minus the byte (delta) before it.
  while (p != lim) {
    --p;
    data[p] = data[p] - data[p - delta];
  }
  var dif = delta;
  do {
    --p;
    data[p] = data[p] - temp[--dif];
  } while (dif != 0);
}

// Delta_Decode
void deltaDecode(
    Uint8List state, int delta, Uint8List data, int off, int size) {
  if (size == 0) return;
  var i = 0;
  var p = off;
  final lim = off + size;

  if (size <= delta) {
    do {
      data[p] = data[p] + state[i++];
    } while (++p != lim);
    // for (; delta != i; state++, delta--) *state = state[i];
    var s = 0;
    for (; delta != i; s++, delta--) {
      state[s] = state[s + i];
    }
    p -= i;
    // do *state++ = *data; while (++data != lim);
    do {
      state[s++] = data[p];
    } while (++p != lim);
    return;
  }

  do {
    data[p] = data[p] + state[i++];
    p++;
  } while (i != delta);
  do {
    data[p] = data[p] + data[p - delta];
  } while (++p != lim);
  p -= delta;
  var s = 0;
  do {
    state[s++] = data[p];
  } while (++p != lim);
}

/// NDelta::CEncoder / CDecoder (DeltaFilter.cpp).
class DeltaFilter implements CompressFilter {
  final bool _encoding;
  final int _delta;
  final Uint8List _state = Uint8List(kDeltaStateSize);

  /// [delta] is the distance, 1 to 256.
  DeltaFilter(this._encoding, this._delta);

  // CDelta::DeltaInit
  @override
  void init() => deltaInit(_state);

  // CEncoder::Filter / CDecoder::Filter
  @override
  int filter(Uint8List data, int off, int size) {
    if (_encoding) {
      deltaEncode(_state, _delta, data, off, size);
    } else {
      deltaDecode(_state, _delta, data, off, size);
    }
    return size;
  }
}
