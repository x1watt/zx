// Folder decoding: 7zDecode.h and 7zDecode.cpp of the LZMA SDK.
//
// 7-Zip binds the coders of a folder with CMixerST / CMixerMT. Here every
// decoder is a pull stream (see codec.dart), so the coder graph of a folder
// is decoded by wrapping streams recursively, starting at the main (unpack)
// coder and walking bonds back to the packed streams. Packed streams are
// WindowInStreams over the archive, so the four streams of BCJ2 can be read
// in an interleaved way (CLockedSequentialInStreamST).

import 'dart:typed_data';

import '../../codec/codec.dart';
import '../../io/streams.dart';
import 'header.dart';
import 'sevenz_in.dart';

/// CBindInfo (CoderMixer2.h) with the maps and the check of bonds.
class BindInfo {
  List<int> coderNumStreams = [];
  List<Bond> bonds = [];
  List<int> packStreams = [];
  int unpackCoder = 0;

  List<int> coderToStream = [];
  List<int> streamToCoder = [];

  // GetNum_Bonds_and_PackStreams
  int get numBondsAndPackStreams => bonds.length + packStreams.length;

  // FindBond_for_PackStream
  int findBondForPackStream(int packStream) {
    for (var i = 0; i < bonds.length; i++) {
      if (bonds[i].packIndex == packStream) return i;
    }
    return -1;
  }

  // FindBond_for_UnpackStream
  int findBondForUnpackStream(int unpackStream) {
    for (var i = 0; i < bonds.length; i++) {
      if (bonds[i].unpackIndex == unpackStream) return i;
    }
    return -1;
  }

  // SetUnpackCoder
  bool setUnpackCoder() {
    var isOk = false;
    for (var i = 0; i < coderNumStreams.length; i++) {
      if (findBondForUnpackStream(i) < 0) {
        if (isOk) return false;
        unpackCoder = i;
        isOk = true;
      }
    }
    return isOk;
  }

  // FindStream_in_PackStreams
  int findStreamInPackStreams(int streamIndex) {
    for (var i = 0; i < packStreams.length; i++) {
      if (packStreams[i] == streamIndex) return i;
    }
    return -1;
  }

  // GetStream_for_Coder
  int getStreamForCoder(int coderIndex) {
    var streamIndex = 0;
    for (var i = 0; i < coderIndex; i++) {
      streamIndex += coderNumStreams[i];
    }
    return streamIndex;
  }

  // CalcMapsAndCheck
  bool calcMapsAndCheck() {
    coderToStream = [];
    streamToCoder = [];
    var numStreams = 0;
    if (coderNumStreams.isEmpty) return false;
    if (coderNumStreams.length - 1 != bonds.length) return false;
    for (var i = 0; i < coderNumStreams.length; i++) {
      coderToStream.add(numStreams);
      for (var j = 0; j < coderNumStreams[i]; j++) {
        streamToCoder.add(i);
      }
      numStreams += coderNumStreams[i];
    }
    if (numStreams != numBondsAndPackStreams) return false;
    // CBondsChecks
    final used = List<bool>.filled(coderNumStreams.length, false);
    bool checkCoder(int coderIndex) {
      if (coderIndex >= used.length || used[coderIndex]) return false;
      used[coderIndex] = true;
      final start = coderToStream[coderIndex];
      for (var i = 0; i < coderNumStreams[coderIndex]; i++) {
        final ind = start + i;
        if (findStreamInPackStreams(ind) >= 0) continue;
        final bond = findBondForPackStream(ind);
        if (bond < 0) return false;
        if (!checkCoder(bonds[bond].unpackIndex)) return false;
      }
      return true;
    }

    if (!checkCoder(unpackCoder)) return false;
    for (final u in used) {
      if (!u) return false;
    }
    return true;
  }
}

// Convert_FolderInfo_to_BindInfo
BindInfo _convertFolderInfoToBindInfo(FolderEx folder) {
  final bi = BindInfo();
  for (final b in folder.bonds) {
    bi.bonds.add(Bond(b.packIndex, b.unpackIndex));
  }
  for (final c in folder.coders) {
    bi.coderNumStreams.add(c.numStreams);
  }
  bi.unpackCoder = folder.unpackCoder;
  bi.packStreams = List<int>.of(folder.packStreams);
  return bi;
}

/// CDecoder (7zDecode.h).
class Decoder {
  /// Decode. Returns the pull stream of the unpacked data of folder
  /// [folderIndex] (like GetMainUnpackStream). When [unpackSize] is given,
  /// only that many bytes are required (a prefix of the folder).
  ///
  /// Throws [SevenZipException] (unsupportedMethod) for unknown methods.
  InStream decode(
      SeekableInStream inStream,
      int startPos,
      Folders folders,
      int folderIndex,
      int? unpackSize,
      DecoderCryptoVars crypto,
      CoderContext ctx) {
    final packPosStart = folders.foStartPackStreamIndex[folderIndex];
    final folderInfo = folders.parseFolderEx(folderIndex);
    if (!folderInfo.isDecodingSupported) {
      throw const SevenZipException(
          'Too many coders', SevenZipError.unsupportedMethod);
    }
    final bindInfo = _convertFolderInfoToBindInfo(folderInfo);
    if (!bindInfo.calcMapsAndCheck()) {
      throw const SevenZipException(
          'Unsupported coder graph', SevenZipError.unsupportedMethod);
    }
    final folderUnpackSize = folders.getFolderUnpackSize(folderIndex);
    if (unpackSize != null && unpackSize > folderUnpackSize) {
      throw const SevenZipException('Bad unpack size', SevenZipError.data);
    }

    // Password (ICryptoSetPassword): asked once per folder that has AES.
    var coderCtx = ctx;
    for (final c in folderInfo.coders) {
      if ((c.methodId >> 8) == 0x403) {
        throw const SevenZipException(
            'RAR codecs are not supported', SevenZipError.unsupportedMethod);
      }
      if (decoderRegistry[c.methodId] == null) {
        throw SevenZipException(
            'Unsupported method ${methodNames[c.methodId] ?? c.methodId.toRadixString(16)}',
            SevenZipError.unsupportedMethod);
      }
      if (c.methodId == MethodId.aes) {
        crypto.isEncrypted = true;
        final get = crypto.getTextPassword;
        if (get == null) {
          throw const SevenZipException(
              'Password is required', SevenZipError.unsupportedMethod);
        }
        if (!crypto.passwordIsDefined) {
          crypto.password = get();
          crypto.passwordIsDefined = true;
        }
        final pw = crypto.password;
        coderCtx = CoderContext(
            password: () => pw, progress: ctx.progress, threads: ctx.threads);
      }
    }

    final unpackStreamIndexStart = folders.foToCoderUnpackSizes[folderIndex];
    final packPositions = folders.packPositions;

    // Packed input number j of the folder (CLimitedSequentialInStream over a
    // locked stream).
    InStream packStream(int j) {
      final pos = startPos + packPositions[packPosStart + j];
      final size =
          packPositions[packPosStart + j + 1] - packPositions[packPosStart + j];
      return WindowInStream(inStream, pos, size);
    }

    // Output of coder [ci] as a pull stream.
    InStream coderOutput(int ci) {
      final coder = folderInfo.coders[ci];
      final start = bindInfo.coderToStream[ci];
      final inputs = <InStream>[];
      for (var j = 0; j < coder.numStreams; j++) {
        final s = start + j;
        final bond = folderInfo.findBondForPackStream(s);
        if (bond >= 0) {
          inputs.add(coderOutput(folderInfo.bonds[bond].unpackIndex));
        } else {
          final index = folderInfo.findInPackStreams(s);
          if (index < 0) {
            throw const SevenZipException(
                'Bad folder', SevenZipError.unsupportedMethod);
          }
          inputs.add(packStream(index));
        }
      }
      // 7-Zip gives the main coder the requested size and turns the finish
      // mode off for a partial unpack. A pull decoder reads only what is
      // asked, so every coder gets its full size (the end checks are then
      // never reached for a prefix) and the main stream is cut below.
      final outSize = folders.coderUnpackSizes[unpackStreamIndexStart + ci];
      final factory = decoderRegistry[coder.methodId]!;
      return factory(
          Uint8List.fromList(coder.props), inputs, outSize, coderCtx);
    }

    final main = coderOutput(bindInfo.unpackCoder);
    return LimitedInStream(main, unpackSize ?? folderUnpackSize);
  }
}
