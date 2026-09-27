// Coding of one .zx block, as jobs for worker isolates (sync_pool.dart):
// the block check, the coder chain, encryption. These functions run in
// any isolate and only take sendable arguments.

import 'dart:typed_data';

import '../../crypto/blake2sp.dart';
import '../../crypto/sha256.dart';
import '../../io/streams.dart';
import '../../sync_pool.dart';
import '../../util/crc32c.dart';
import '../../util/xxhash.dart';
import 'zx_codecs.dart';
import 'zx_crypto.dart';
import 'zx_format.dart';

/// The check of type [type] over b[off, end).
Uint8List zxComputeCheck(int type, Uint8List b, [int off = 0, int? end]) {
  final e = end ?? b.length;
  switch (type) {
    case ZxCheck.none:
      return Uint8List(0);
    case ZxCheck.crc32c:
      final out = Uint8List(4);
      setUint32LE(out, 0, Crc32c.of(b, off, e));
      return out;
    case ZxCheck.xxh64:
      final out = Uint8List(8);
      setUint64LE(out, 0, xxh64(b, off, e));
      return out;
    case ZxCheck.sha256:
      return (Sha256()..update(b, off, e - off)).digest();
    case ZxCheck.blake2sp:
      return (Blake2sp()..update(b, off, e - off)).digest();
  }
  throw SevenZipException(
      'zx: unsupported check type $type', SevenZipError.unsupportedMethod);
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a[i] ^ b[i];
  }
  return d == 0;
}

/// The input of [zxEncodeBlockJob].
class ZxEncodeArg {
  final Uint8List data;
  final List<ZxCoderSpec> coders;
  final int checkType;

  /// The AES and MAC keys when the block is encrypted.
  final Uint8List? aesKey;
  final Uint8List? macKey;
  const ZxEncodeArg(this.data, this.coders, this.checkType,
      [this.aesKey, this.macKey]);
}

/// An encoded block, before its header: the chain's coders with their
/// props (empty for store), the payload (for an encrypted block: nonce,
/// ciphertext and room for the MAC), the unpacked size and the check.
class ZxEncodedBlock {
  final List<ZxCoder> coders;
  final Uint8List payload;
  final int unpackedSize;
  final int checkType;
  final Uint8List check;
  const ZxEncodedBlock(
      this.coders, this.payload, this.unpackedSize, this.checkType, this.check);

  SyncJobResult toResult() {
    final w = ZxBytes(64);
    w.vint(unpackedSize);
    w.u8(checkType);
    w.bytes(check);
    w.vint(coders.length);
    for (final c in coders) {
      w.vint(c.codecId);
      w.vint(c.props.length);
      w.bytes(c.props);
    }
    return SyncJobResult(payload, w.toBytes());
  }

  static ZxEncodedBlock fromResult(SyncJobResult r) {
    final m = ZxRead(r.meta);
    final unpacked = m.vint();
    final ct = m.u8();
    final check = Uint8List.fromList(m.bytes(ZxCheck.size(ct)));
    final n = m.vint();
    final coders = <ZxCoder>[];
    for (var i = 0; i < n; i++) {
      final id = m.vint();
      final ps = m.vint();
      coders.add(ZxCoder(id, Uint8List.fromList(m.bytes(ps))));
    }
    return ZxEncodedBlock(coders, r.data, unpacked, ct, check);
  }
}

/// Encodes one block: its check, its chain (stored instead when the chain
/// does not make it smaller), its encryption.
ZxEncodedBlock zxEncodeBlock(ZxEncodeArg a) {
  final data = a.data;
  // an encrypted block has no check of its plaintext in the clear header
  // (it would identify the content): its MAC protects it
  final checkType = a.aesKey != null ? ZxCheck.none : a.checkType;
  final check = zxComputeCheck(checkType, data);
  var coders = <ZxCoder>[];
  var payload = data;
  if (a.coders.isNotEmpty && data.isNotEmpty) {
    // the filters and zpaq change their input: keep it for the fallback
    var keep = false;
    for (final c in a.coders) {
      final info = zxCodecById(c.codecId);
      if (info == null || info.isFilter || c.codecId == ZxCodecId.zpaq) {
        keep = true;
      }
    }
    final input = keep ? Uint8List.fromList(data) : data;
    final (p, cs) = zxEncodeChain(input, a.coders);
    if (p.length < data.length) {
      payload = p;
      coders = cs;
    }
  }
  final ak = a.aesKey, mk = a.macKey;
  if (ak != null && mk != null) {
    // copy: the store chain gives the input itself
    payload = ZxKeys(ak, mk).seal(Uint8List.fromList(payload));
  }
  return ZxEncodedBlock(coders, payload, data.length, checkType, check);
}

/// [zxEncodeBlock] as a [SyncJobFn].
SyncJobResult zxEncodeBlockJob(Object? arg) =>
    zxEncodeBlock(arg as ZxEncodeArg).toResult();

/// The input of [zxDecodeBlockJob].
class ZxDecodeArg {
  /// The block, header and payload, as read from the file.
  final Uint8List raw;
  final ZxChain chain;
  final Uint8List? aesKey;
  final Uint8List? macKey;
  const ZxDecodeArg(this.raw, this.chain, [this.aesKey, this.macKey]);
}

/// Decodes one block read from the file (header and payload): checks the
/// header, the MAC of an encrypted block, decodes the chain and checks the
/// unpacked data. Throws [SevenZipException] with [SevenZipError.crc] for
/// a check mismatch, [SevenZipError.data] for damaged data.
Uint8List zxDecodeBlock(ZxDecodeArg a) {
  final raw = a.raw;
  final h = ZxBlockHeader.tryParse(raw, 0, raw.length);
  if (h == null) {
    throw const SevenZipException('zx: damaged block header');
  }
  if (h.headerSize + h.packedSize != raw.length) {
    throw const SevenZipException('zx: block size mismatch');
  }
  if (h.unpackedSize > zxMaxBlockSize) {
    throw const SevenZipException(
        'zx: block too large', SevenZipError.unsupported);
  }
  var payload = Uint8List.sublistView(raw, h.headerSize);
  final ak = a.aesKey, mk = a.macKey;
  if (ak != null && mk != null) {
    payload = ZxKeys(ak, mk).open(h.macBytes, payload);
  }
  final Uint8List data;
  try {
    data = zxDecodeChain(payload, a.chain, h.unpackedSize);
  } on SevenZipException {
    rethrow;
  } on RangeError {
    throw const SevenZipException('zx: damaged block data');
  } on ArgumentError {
    throw const SevenZipException('zx: damaged block data');
  }
  if (h.checkType != ZxCheck.none) {
    if (ZxCheck.size(h.checkType) < 0) {
      throw SevenZipException('zx: unsupported check type ${h.checkType}',
          SevenZipError.unsupportedMethod);
    }
    if (!_sameBytes(zxComputeCheck(h.checkType, data), h.check)) {
      throw const SevenZipException(
          'zx: block check mismatch (damaged data)', SevenZipError.crc);
    }
  }
  return data;
}

/// [zxDecodeBlock] as a [SyncJobFn].
SyncJobResult zxDecodeBlockJob(Object? arg) =>
    SyncJobResult(zxDecodeBlock(arg as ZxDecodeArg));
