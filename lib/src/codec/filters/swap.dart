// Byte swap filters SWAP2 and SWAP4: port of CPP/7zip/Compress/ByteSwap.cpp
// (and the plain C loops of C/SwapBytes.c). Encoding and decoding are the
// same operation.

import 'dart:typed_data';

import 'filter_coder.dart';

// z7_SwapBytes2
void z7SwapBytes2(Uint8List d, int off, int numItems) {
  final end = off + numItems * 2;
  for (var p = off; p != end; p += 2) {
    final b0 = d[p];
    d[p] = d[p + 1];
    d[p + 1] = b0;
  }
}

// z7_SwapBytes4
void z7SwapBytes4(Uint8List d, int off, int numItems) {
  final end = off + numItems * 4;
  for (var p = off; p != end; p += 4) {
    final b0 = d[p];
    final b1 = d[p + 1];
    d[p] = d[p + 3];
    d[p + 1] = d[p + 2];
    d[p + 2] = b1;
    d[p + 3] = b0;
  }
}

/// CByteSwap2
class ByteSwap2Filter implements CompressFilter {
  // CByteSwap2::Init
  @override
  void init() {}

  // CByteSwap2::Filter
  @override
  int filter(Uint8List data, int off, int size) {
    size &= ~1;
    z7SwapBytes2(data, off, size >> 1);
    return size;
  }
}

/// CByteSwap4
class ByteSwap4Filter implements CompressFilter {
  // CByteSwap4::Init
  @override
  void init() {}

  // CByteSwap4::Filter
  @override
  int filter(Uint8List data, int off, int size) {
    size &= ~3;
    z7SwapBytes4(data, off, size >> 2);
    return size;
  }
}
