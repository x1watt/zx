// Port of CPP/7zip/Common/FilterCoder.cpp: drives an ICompressFilter (a
// buffer transform that may process less than it is given) over a stream.
//
// [FilterReader] is CFilterCoder::Read (pull, used for decoding and for the
// pull encoders of [FilterCoder]); [FilterWriter] is CFilterCoder::Write and
// OutStreamFinish (push, used by the AES encoder).

import 'dart:typed_data';

import '../../io/streams.dart';

/// The Dart counterpart of ICompressFilter.
///
/// [filter] converts data in place and returns the number of bytes that
/// were processed. It may return less than [size] (BCJ, ARMT: the unfinished
/// tail waits for more data, or passes unchanged at the end of the stream).
/// A block filter (AES) returns a value larger than [size] when it needs a
/// full block; see CFilterCoder for how that case is handled.
abstract class CompressFilter {
  void init();
  int filter(Uint8List data, int off, int size);
}

/// kBufSize in FilterCoder.cpp.
const int kFilterBufSize = 1 << 21;

// CFilterCoder::Alloc: the size is aligned down to 4 KiB, 4 KiB at least.
int _allocSize(int size) {
  const kMinSize = 1 << 12;
  size &= ~(kMinSize - 1);
  if (size < kMinSize) size = kMinSize;
  return size;
}

/// CFilterCoder in read mode (SetInStream, SetOutStreamSize, Read).
class FilterReader implements InStream {
  final InStream _inStream;
  final CompressFilter _filter;
  final bool _encodeMode;
  final int? _outSize;
  final int _bufSize;
  Uint8List? _buf;
  int _bufPos = 0;
  int _convPos = 0;
  int _convSize = 0;
  int _nowPos64 = 0;

  FilterReader(this._inStream, this._filter,
      {bool encodeMode = false, int? outSize, int bufSize = kFilterBufSize})
      : _encodeMode = encodeMode,
        _outSize = outSize,
        _bufSize = _allocSize(bufSize) {
    // CFilterCoder::SetOutStreamSize: InitSpecVars + Init_and_Alloc.
    _filter.init();
  }

  // CFilterCoder::Read
  @override
  int read(Uint8List data, int off, int size) {
    final outSize = _outSize;
    // Not in the C code: once the declared size is reached, stop without
    // reading more input (the C version reads, then returns 0 bytes).
    if (outSize != null && _nowPos64 >= outSize) return 0;
    final buf = _buf ??= Uint8List(_bufSize);
    var processedSize = 0;
    while (size != 0) {
      if (_convSize != 0) {
        if (size > _convSize) size = _convSize;
        if (outSize != null) {
          final rem = outSize - _nowPos64;
          if (size > rem) size = rem;
        }
        data.setRange(off, off + size, buf, _convPos);
        _convPos += size;
        _convSize -= size;
        _nowPos64 += size;
        processedSize = size;
        break;
      }

      final convPos = _convPos;
      if (convPos != 0) {
        final num = _bufPos - convPos;
        buf.setRange(0, num, buf, convPos);
        _bufPos = num;
        _convPos = 0;
      }

      // ReadStream: reads until the buffer is full or the input ends.
      _bufPos += readFully(_inStream, buf, _bufPos, _bufSize - _bufPos);

      final convSize = _filter.filter(buf, 0, _bufPos);
      _convSize = convSize;

      var bufPos = _bufPos;

      if (convSize == 0) {
        if (bufPos == 0) break;
        // BCJ: the unprocessed tail at the end of the stream is copied as is.
        _convSize = bufPos;
        continue;
      }

      if (convSize > bufPos) {
        // AES
        if (convSize > _bufSize) {
          throw const SevenZipException('Filter error (E_FAIL)');
        }
        if (!_encodeMode) {
          throw const SevenZipException(
              'Encrypted data size is not a multiple of the block size');
        }
        do {
          buf[bufPos] = 0;
        } while (++bufPos != convSize);
        _bufPos = bufPos;
        _convSize = _filter.filter(buf, 0, convSize);
        if (_convSize != _bufPos) {
          throw const SevenZipException('Filter error (E_FAIL)');
        }
      }
    }
    return processedSize;
  }
}

/// CFilterCoder in write mode (SetOutStream, InitEncoder, Write,
/// OutStreamFinish). Only the encode mode is needed here (AES encoder).
class FilterWriter implements OutStream {
  final OutStream _outStream;
  final CompressFilter _filter;
  final bool _encodeMode;
  final int _bufSize;
  final Uint8List _buf;
  int _bufPos = 0;
  int _convPos = 0;
  int _convSize = 0;
  int _nowPos64 = 0;

  FilterWriter(this._outStream, this._filter,
      {bool encodeMode = true, int bufSize = kFilterBufSize})
      : _encodeMode = encodeMode,
        _bufSize = _allocSize(bufSize),
        _buf = Uint8List(_allocSize(bufSize)) {
    // CFilterCoder::InitEncoder
    _filter.init();
  }

  /// Number of bytes written to the output stream so far.
  int get outSize => _nowPos64;

  // CFilterCoder::Flush2
  void _flush2() {
    if (_convSize != 0) {
      _outStream.write(_buf, _convPos, _convSize);
      _convPos += _convSize;
      _nowPos64 += _convSize;
      _convSize = 0;
    }
    final convPos = _convPos;
    if (convPos != 0) {
      final num = _bufPos - convPos;
      _buf.setRange(0, num, _buf, convPos);
      _bufPos = num;
      _convPos = 0;
    }
  }

  // CFilterCoder::Write
  @override
  void write(Uint8List data, int off, int size) {
    while (size != 0) {
      _flush2();
      if (_bufPos != _bufSize) {
        var num = _bufSize - _bufPos;
        if (num > size) num = size;
        _buf.setRange(_bufPos, _bufPos + num, data, off);
        size -= num;
        off += num;
        _bufPos += num;
        if (_bufPos != _bufSize) continue;
      }
      _convSize = _filter.filter(_buf, 0, _bufPos);
      if (_convSize == 0) break;
      if (_convSize > _bufPos) {
        _convSize = 0;
        throw const SevenZipException('Filter error (E_FAIL)');
      }
    }
  }

  /// Writes the converted data that is ready and flushes the output. A
  /// partial block stays buffered until [finish].
  @override
  void flush() {
    _flush2();
    _outStream.flush();
  }

  // CFilterCoder::OutStreamFinish
  void finish() {
    for (;;) {
      _flush2();
      if (_bufPos == 0) break;
      final convSize = _filter.filter(_buf, 0, _bufPos);
      _convSize = convSize;
      var bufPos = _bufPos;
      if (convSize == 0) {
        _convSize = bufPos;
      } else if (convSize > bufPos) {
        // AES
        if (convSize > _bufSize) {
          _convSize = 0;
          throw const SevenZipException('Filter error (E_FAIL)');
        }
        if (!_encodeMode) {
          _convSize = 0;
          throw const SevenZipException(
              'Encrypted data size is not a multiple of the block size');
        }
        for (; bufPos < convSize; bufPos++) {
          _buf[bufPos] = 0;
        }
        _bufPos = bufPos;
        _convSize = _filter.filter(_buf, 0, bufPos);
        if (_convSize != _bufPos) {
          throw const SevenZipException('Filter error (E_FAIL)');
        }
      }
    }
    _outStream.flush();
  }
}
