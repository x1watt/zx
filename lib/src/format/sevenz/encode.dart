// Folder encoding: 7zEncode.h and 7zEncode.cpp of the LZMA SDK, plus the
// CInOutTempBuffer of InOutTempBuffer.cpp.
//
// 7-Zip runs the coders of a folder with a coder mixer (CMixerMT, one
// thread per coder). Here the graph is run synchronously: pull shaped
// coders (filters) are chained as pull streams, push shaped ones (7zAES)
// wrap their output, and when a push producer feeds a pull consumer (a
// compressor after BCJ2, or a compressor after a compressor) the data goes
// through a temp buffer and the consumer runs after the producer is done.
// Pack stream 0 goes straight to the archive, the other pack streams are
// buffered and appended after it, as in CEncoder::Encode1.

import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../io/streams.dart';
import 'compression_mode.dart';
import 'decode.dart';
import 'header.dart';
import 'method_factory.dart';
import '../../common/method_props.dart';

/// CInOutTempBuffer: keeps data in memory up to [memLimit] bytes, then in a
/// temporary file.
class InOutTempBuffer implements OutStream {
  static const int _kBufSize = 1 << 20;
  final int memLimit;
  final List<Uint8List> _bufs = [];
  int _size = 0;
  File? _file;
  RandomAccessFile? _raf;
  bool _closedForWrite = false;

  InOutTempBuffer({this.memLimit = 16 << 20});

  // GetDataSize
  int get dataSize => _size;

  @override
  void write(Uint8List buf, int off, int len) {
    if (_closedForWrite) throw StateError('temp buffer closed');
    while (len > 0) {
      if (_raf != null) {
        _raf!.writeFromSync(buf, off, off + len);
        _size += len;
        return;
      }
      if (_size == _bufs.length * _kBufSize) {
        // all buffers are full
        if (_size + _kBufSize > memLimit && _size != 0) {
          _spill();
          continue;
        }
        _bufs.add(Uint8List(_kBufSize));
      }
      final last = _bufs.last;
      final pos = _size - (_bufs.length - 1) * _kBufSize;
      var n = _kBufSize - pos;
      if (n > len) n = len;
      last.setRange(pos, pos + n, buf, off);
      _size += n;
      off += n;
      len -= n;
    }
  }

  void _spill() {
    final dir = Directory.systemTemp.createTempSync('zx7z');
    final f = File('${dir.path}/tmp.bin');
    final raf = f.openSync(mode: FileMode.write);
    for (var i = 0; i < _bufs.length; i++) {
      raf.writeFromSync(_bufs[i], 0, _kBufSize);
    }
    _bufs.clear();
    _file = f;
    _raf = raf;
  }

  @override
  void flush() {}

  /// Ends writing (the reader sees exactly [dataSize] bytes).
  void closeWrite() {
    _closedForWrite = true;
    _raf?.flushSync();
  }

  /// A reader over the stored data.
  InStream reader() {
    closeWrite();
    final raf = _raf;
    if (raf != null) {
      raf.setPositionSync(0);
      return _FileTempReader(raf, _size);
    }
    return _MemTempReader(_bufs, _size, _kBufSize);
  }

  // WriteToStream
  void writeToStream(OutStream out) {
    copyStream(reader(), out);
  }

  /// Frees memory and removes the temporary file.
  void dispose() {
    _bufs.clear();
    final raf = _raf;
    if (raf != null) {
      raf.closeSync();
      _raf = null;
      try {
        _file!.parent.deleteSync(recursive: true);
      } on FileSystemException {
        // ignore
      }
    }
  }
}

class _MemTempReader implements InStream {
  final List<Uint8List> _bufs;
  final int _size;
  final int _bufSize;
  int _pos = 0;
  _MemTempReader(this._bufs, this._size, this._bufSize);
  @override
  int read(Uint8List buf, int off, int len) {
    final rem = _size - _pos;
    if (rem <= 0) return 0;
    if (len > rem) len = rem;
    final b = _bufs[_pos ~/ _bufSize];
    final inBuf = _pos % _bufSize;
    if (len > _bufSize - inBuf) len = _bufSize - inBuf;
    buf.setRange(off, off + len, b, inBuf);
    _pos += len;
    return len;
  }
}

class _FileTempReader implements InStream {
  final RandomAccessFile _raf;
  int _rem;
  _FileTempReader(this._raf, this._rem);
  @override
  int read(Uint8List buf, int off, int len) {
    if (_rem <= 0) return 0;
    if (len > _rem) len = _rem;
    final n = _raf.readIntoSync(buf, off, off + len);
    _rem -= n;
    return n;
  }
}

/// An output of a coder inside the running graph.
class _Sink implements OutStream {
  final OutStream out;
  final void Function()? _onClose;
  _Sink(this.out, [this._onClose]);
  @override
  void write(Uint8List buf, int off, int len) => out.write(buf, off, len);
  @override
  void flush() {}
  void close() => _onClose?.call();
}

/// CEncoder (7zEncode.h).
class Encoder {
  final CompressionMethodMode _options;
  final BindInfo _bindInfo = BindInfo();
  final List<int> _decompressionMethods = [];

  List<int> _srcInToDestOut = [];
  List<int> _srcOutToDestIn = [];
  List<int> _destOutToSrcIn = [];

  bool _constructed = false;
  List<CoderEncoder>? _coders;

  /// Bytes that went through each bond in the last Encode1
  /// (CMixer::GetBondStreamSize).
  List<int Function()> _bondSizes = [];

  final int tempBufferMemLimit;

  Encoder(CompressionMethodMode options, {this.tempBufferMemLimit = 16 << 20})
      : _options = options.copy() {
    if (options.isEmpty) throw StateError('CEncoder: empty options');
  }

  // InitBindConv
  void _initBindConv() {
    var numIn = _bindInfo.coderNumStreams.length;
    _srcInToDestOut = List<int>.filled(numIn, 0);
    _destOutToSrcIn = List<int>.filled(numIn, 0);
    var numOut = _bindInfo.numBondsAndPackStreams;
    _srcOutToDestIn = List<int>.filled(numOut, 0);
    var destIn = 0;
    var destOut = 0;
    for (var i = _bindInfo.coderNumStreams.length; i != 0;) {
      i--;
      final numStreams = _bindInfo.coderNumStreams[i];
      numIn--;
      numOut -= numStreams;
      _srcInToDestOut[numIn] = destOut;
      _destOutToSrcIn[destOut] = numIn;
      destOut++;
      for (var j = 0; j < numStreams; j++, destIn++) {
        _srcOutToDestIn[numOut + j] = destIn;
      }
    }
  }

  // SetFolder
  void _setFolder(Folder folder) {
    final nb = _bindInfo.bonds.length;
    folder.bonds = [];
    for (var i = 0; i < nb; i++) {
      final mixerBond = _bindInfo.bonds[nb - 1 - i];
      folder.bonds.add(Bond(_srcOutToDestIn[mixerBond.packIndex],
          _srcInToDestOut[mixerBond.unpackIndex]));
    }
    final nc = _bindInfo.coderNumStreams.length;
    folder.coders = [];
    for (var i = 0; i < nc; i++) {
      folder.coders.add(CoderInfo()
        ..numStreams = _bindInfo.coderNumStreams[nc - 1 - i]
        ..methodId = _decompressionMethods[i]);
    }
    folder.packStreams = [
      for (final p in _bindInfo.packStreams) _srcOutToDestIn[p]
    ];
  }

  // EncoderConstr
  void _encoderConstr() {
    if (_constructed) return;
    if (_options.methods.isEmpty) {
      // it has only password method
      if (!_options.passwordIsDefined) throw StateError('no methods');
      if (_options.bonds.isNotEmpty) throw StateError('bonds without methods');
      _options.methods.add(MethodFull()
        ..id = MethodId.aes
        ..numStreams = 1);
      _bindInfo.coderNumStreams.add(1);
      _bindInfo.packStreams.add(0);
      _bindInfo.unpackCoder = 0;
    } else {
      var numOutStreams = 0;
      for (var i = 0; i < _options.methods.length; i++) {
        final methodFull = _options.methods[i];
        final numStreams = methodFull.numStreams;
        if (_options.bonds.isEmpty) {
          // bonds via first streams of coders
          if (i != _options.methods.length - 1) {
            _bindInfo.bonds.add(Bond(numOutStreams, i + 1));
          } else if (numStreams != 0) {
            _bindInfo.packStreams.insert(0, numOutStreams);
          }
          for (var j = 1; j < numStreams; j++) {
            _bindInfo.packStreams.add(numOutStreams + j);
          }
        }
        numOutStreams += numStreams;
        _bindInfo.coderNumStreams.add(numStreams);
      }

      if (_options.bonds.isNotEmpty) {
        for (final bond in _options.bonds) {
          if (bond.inCoder >= _bindInfo.coderNumStreams.length ||
              bond.outCoder >= _bindInfo.coderNumStreams.length ||
              bond.outStream >= _bindInfo.coderNumStreams[bond.outCoder]) {
            throw const InvalidArgException('Bad bond');
          }
          _bindInfo.bonds.add(Bond(
              _bindInfo.getStreamForCoder(bond.outCoder) + bond.outStream,
              bond.inCoder));
        }
        for (var i = 0; i < numOutStreams; i++) {
          if (_bindInfo.findBondForPackStream(i) == -1) {
            _bindInfo.packStreams.add(i);
          }
        }
      }

      if (!_bindInfo.setUnpackCoder()) {
        throw const InvalidArgException('Bad coder graph');
      }
      if (!_bindInfo.calcMapsAndCheck()) {
        throw const InvalidArgException('Bad coder graph');
      }

      if (_bindInfo.packStreams.length != 1) {
        // Place the pack stream of the main path first.
        var ci = _bindInfo.unpackCoder;
        for (;;) {
          if (_bindInfo.coderNumStreams[ci] == 0) break;
          final outIndex = _bindInfo.coderToStream[ci];
          final bond = _bindInfo.findBondForPackStream(outIndex);
          if (bond >= 0) {
            ci = _bindInfo.bonds[bond].unpackIndex;
            continue;
          }
          final si = _bindInfo.findStreamInPackStreams(outIndex);
          if (si >= 0) {
            final v = _bindInfo.packStreams.removeAt(si);
            _bindInfo.packStreams.insert(0, v);
          }
          break;
        }
      }

      if (_options.passwordIsDefined) {
        final numCryptoStreams = _bindInfo.packStreams.length;
        final numInStreams = _bindInfo.coderNumStreams.length;
        for (var i = 0; i < numCryptoStreams; i++) {
          _bindInfo.bonds.add(Bond(_bindInfo.packStreams[i], numInStreams + i));
        }
        _bindInfo.packStreams.clear();
        for (var i = 0; i < numCryptoStreams; i++) {
          _options.methods.add(MethodFull()
            ..numStreams = 1
            ..id = MethodId.aes);
          _bindInfo.coderNumStreams.add(1);
          _bindInfo.packStreams.add(numOutStreams++);
        }
      }
    }

    for (var i = _options.methods.length; i != 0;) {
      _decompressionMethods.add(_options.methods[--i].id);
    }
    if (_bindInfo.coderNumStreams.length > 16) {
      throw const InvalidArgException('Too many coders');
    }
    if (_bindInfo.numBondsAndPackStreams > 16) {
      throw const InvalidArgException('Too many streams');
    }
    if (!_bindInfo.calcMapsAndCheck()) {
      throw const InvalidArgException('Bad coder graph');
    }
    _initBindConv();
    _constructed = true;
  }

  // CreateMixerCoder
  void _createMixerCoder(int? inSizeForReduce, ProgressCallback? progress) {
    final coders = <CoderEncoder>[];
    for (final methodFull in _options.methods) {
      final ctx = EncoderContext(
          password: _options.passwordIsDefined ? _options.password : null,
          threads: methodFull.setNumThreads ? methodFull.numThreads : 1,
          progress: progress);
      final cod = createEncoder(methodFull.id, methodFull,
          dataSizeReduce: inSizeForReduce, ctx: ctx);
      final numStreams = cod is Bcj2CoderEncoder ? 4 : 1;
      if (numStreams != methodFull.numStreams) {
        throw StateError('Coder stream count mismatch');
      }
      coders.add(cod);
    }
    _coders = coders;
  }

  /// Encode1: encodes [inStream] as one folder. The folder description is
  /// stored in [folderItem]; the pack stream sizes are added to [packSizes].
  void encode1(InStream inStream, int? inSizeForReduce, int expectedDataSize,
      Folder folderItem, OutStream outStream, List<int> packSizes,
      {ProgressCallback? progress, SubStreamSizeFunction? subStreamSize}) {
    _encoderConstr();
    if (_coders == null) _createMixerCoder(inSizeForReduce, progress);
    final coders = _coders!;

    final numPack = _bindInfo.packStreams.length;
    final tempBuffers = <InOutTempBuffer>[
      for (var i = 1; i < numPack; i++)
        InOutTempBuffer(memLimit: tempBufferMemLimit)
    ];
    try {
      _setFolder(folderItem);
      // ICompressSetCoderPropertiesOpt(kExpectedDataSize)
      for (final c in coders) {
        c.setExpectedDataSize(expectedDataSize);
      }

      final outStreamSizeCount = CountingOutStream(outStream);
      final outStreams = <OutStream>[
        if (numPack != 0) outStreamSizeCount,
        ...tempBuffers
      ];

      _code(coders, inStream, outStreams, progress, subStreamSize);

      if (numPack != 0) packSizes.add(outStreamSizeCount.count);
      for (final t in tempBuffers) {
        t.writeToStream(outStream);
        packSizes.add(t.dataSize);
      }

      // FillProps_from_Coder (after Code, v23)
      final numMethods = coders.length;
      for (var i = 0; i < numMethods; i++) {
        folderItem.coders[numMethods - 1 - i].props =
            Uint8List.fromList(coders[i].props);
      }
    } finally {
      for (final t in tempBuffers) {
        t.dispose();
      }
    }
  }

  // CMixer::Code for the encode direction.
  void _code(
      List<CoderEncoder> coders,
      InStream input,
      List<OutStream> outStreams,
      ProgressCallback? progress,
      SubStreamSizeFunction? subStreamSize) {
    final bi = _bindInfo;
    final bondSizes = List<int Function()>.filled(bi.bonds.length, () => 0);
    final deferred = Queue<void Function()>();
    final temps = <InOutTempBuffer>[];

    late void Function(int c, InStream input, bool isMain) runCoder;

    _Sink pushSink(int streamIdx) {
      final bond = bi.findBondForPackStream(streamIdx);
      if (bond < 0) {
        final p = bi.findStreamInPackStreams(streamIdx);
        return _Sink(outStreams[p]);
      }
      final d = bi.bonds[bond].unpackIndex;
      final enc = coders[d];
      if (enc is PushCoderEncoder) {
        final inner = pushSink(bi.coderToStream[d]);
        final pe = enc.openFolder(inner);
        final counting = CountingOutStream(pe);
        bondSizes[bond] = () => counting.count;
        return _Sink(counting, () {
          pe.close();
          inner.close();
        });
      }
      final tmp = InOutTempBuffer(memLimit: tempBufferMemLimit);
      temps.add(tmp);
      bondSizes[bond] = () => tmp.dataSize;
      return _Sink(tmp, () {
        tmp.closeWrite();
        deferred.add(() {
          runCoder(d, tmp.reader(), false);
          tmp.dispose();
        });
      });
    }

    void deliverPull(int streamIdx, InStream s, bool isMain) {
      final bond = bi.findBondForPackStream(streamIdx);
      if (bond >= 0) {
        final counting = CountingInStream(s);
        bondSizes[bond] = () => counting.count;
        runCoder(bi.bonds[bond].unpackIndex, counting, isMain);
        return;
      }
      final p = bi.findStreamInPackStreams(streamIdx);
      copyStream(s, outStreams[p]);
    }

    runCoder = (int c, InStream input, bool isMain) {
      final enc = coders[c];
      final s0 = bi.coderToStream[c];
      switch (enc) {
        case FilterCoderEncoder():
          deliverPull(s0, enc.filter.encoder(input), isMain);
        case CompressorCoderEncoder():
          final sink = pushSink(s0);
          enc.compressor
              .encode(input, sink, progress: isMain ? progress : null);
          sink.close();
        case PushCoderEncoder():
          final sink = pushSink(s0);
          final pe = enc.openFolder(sink);
          copyStream(input, pe);
          pe.close();
          sink.close();
        case Bcj2CoderEncoder():
          final sinks = [for (var k = 0; k < 4; k++) pushSink(s0 + k)];
          // The folder input gives the file sizes (GetSubStreamSize) when
          // BCJ2 reads it directly.
          enc.encode(input, sinks[0], sinks[1], sinks[2], sinks[3],
              subStreamSize: c == bi.unpackCoder ? subStreamSize : null,
              progress: isMain ? progress : null);
          for (final s in sinks) {
            s.close();
          }
      }
    };

    try {
      runCoder(bi.unpackCoder, input, true);
      while (deferred.isNotEmpty) {
        deferred.removeFirst()();
      }
    } finally {
      for (final t in temps) {
        t.dispose();
      }
    }
    _bondSizes = bondSizes;
  }

  /// Encode_Post: adds the unpack size of every coder of the last folder.
  void encodePost(int unpackSize, List<int> coderUnpackSizes) {
    for (var i = 0; i < _bindInfo.coderNumStreams.length; i++) {
      final bond = _bindInfo.findBondForUnpackStream(_destOutToSrcIn[i]);
      coderUnpackSizes.add(bond < 0 ? unpackSize : _bondSizes[bond]());
    }
  }
}
