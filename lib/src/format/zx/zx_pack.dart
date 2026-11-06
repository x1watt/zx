// One file packed into a .zx archive held in memory, and back: the way
// to keep a single small file encrypted (a key file, a settings file, a
// blob next to a database) with the archive's own encryption, without a
// database and without an isolate. Synchronous; for files of a few
// megabytes (the whole archive is in memory).

import 'dart:typed_data';

import '../../io/streams.dart';
import '../archive_types.dart';
import 'zx_codecs.dart';
import 'zx_crypto.dart' show zxDefaultScryptLog2N;
import 'zx_format.dart';
import 'zx_handler.dart';
import 'zx_writer.dart';

/// Packs [data] as the one entry [name] of a new .zx archive and returns
/// the archive's bytes. With [password] the data and the Index are
/// encrypted (AES-256-CTR, HMAC-SHA-256); [scryptLog2N] is the cost of the
/// key (see ZxDbStoreOptions.scryptLog2N: 1 when the password is already
/// a random key). [compression] is `'none'`, `'fast'` (LZ4) or `'max'`
/// (LZMA2); already compressed media gains nothing from `'max'`.
Uint8List zxPackBytes(Uint8List data,
    {String name = 'data',
    String? password,
    int scryptLog2N = zxDefaultScryptLog2N,
    String compression = 'fast',
    int? timeNs}) {
  final o = ZxWriteOptions()
    ..threads = 1
    ..dedup = false
    ..password = password == null || password.isEmpty ? null : password
    ..scryptLog2N = scryptLog2N
    ..coders = switch (compression) {
      'none' => const [ZxCoderSpec(ZxCodecId.store, ZxCoderConfig())],
      'fast' => const [ZxCoderSpec(ZxCodecId.lz4, ZxCoderConfig(level: 1))],
      'max' => const [ZxCoderSpec(ZxCodecId.lzma2, ZxCoderConfig(level: 9))],
      _ => throw ArgumentError.value(compression, 'compression'),
    };
  if (timeNs != null) o.time = timeNs;
  final out = MemoryOutStream();
  final w = ZxWriter.create(o, (h) => ZxStreamSink(out));
  w.addNew(ZxEntry(name, ZxKind.file)..mTime = o.time, MemoryInStream(data),
      knownSize: data.length);
  w.finish();
  return Uint8List.fromList(out.toBytes());
}

/// Whether [bytes] start like a .zx archive (its signature).
bool zxLooksPacked(Uint8List bytes) {
  if (bytes.length < zxMagic.length) return false;
  for (var i = 0; i < zxMagic.length; i++) {
    if (bytes[i] != zxMagic[i]) return false;
  }
  return true;
}

/// The data of the first file of the .zx archive [bytes] (written by
/// [zxPackBytes]). Throws [SevenZipException] (kind
/// [SevenZipError.wrongPassword] for a missing or wrong password,
/// [SevenZipError.isNotArc] for bytes that are not a .zx archive, and
/// [SevenZipError.crc] / [SevenZipError.data] for damage).
Uint8List zxUnpackBytes(Uint8List bytes, {String? password}) {
  final h = ZxHandler();
  final pw = password == null || password.isEmpty ? null : password;
  if (!h.open(MemoryInStream(bytes), password: () => pw)) {
    throw const SevenZipException(
        'zx: not a .zx archive', SevenZipError.isNotArc);
  }
  for (var i = 0; i < h.numberOfItems; i++) {
    if (h.getProperty(i, Kpid.isDir) == true) continue;
    final cb = _OneFile(pw);
    h.extract([i], false, cb, password: () => pw);
    switch (cb.result) {
      case OperationResult.ok:
        return Uint8List.fromList(cb.out.toBytes());
      case OperationResult.wrongPassword:
        throw const SevenZipException(
            'zx: wrong password', SevenZipError.wrongPassword);
      case OperationResult.crcError:
        throw const SevenZipException('zx: CRC error', SevenZipError.crc);
      default:
        throw const SevenZipException('zx: data error', SevenZipError.data);
    }
  }
  throw const SevenZipException('zx: the archive holds no file',
      SevenZipError.data);
}

class _OneFile extends ArchiveExtractCallback
    implements CryptoGetTextPassword {
  final String? password;
  final MemoryOutStream out = MemoryOutStream();
  int result = -1;
  _OneFile(this.password);

  @override
  OutStream? getStream(int index, int askMode) =>
      askMode == AskMode.extract ? out : null;

  @override
  void setOperationResult(int opRes) => result = opRes;

  @override
  String cryptoGetTextPassword() =>
      password ?? (throw const SevenZipException(
          'zx: a password is needed', SevenZipError.wrongPassword));
}
