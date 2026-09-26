// Writing the zip structures, from the PKWARE APPNOTE: local headers,
// data descriptors, central directory records, the Zip64 end of central
// directory record and locator, and the end of central directory record.

import 'dart:typed_data';

import '../../io/streams.dart';
import 'zip_header.dart';
import 'zip_in.dart';

/// An item to write: the header fields and the extra fields of the local
/// header and of the central directory.
class ZipOutItem {
  int versionMadeBy = 0;
  int versionNeeded = 10;
  int flags = 0;
  int method = 0;
  int dosTime = 0;
  int crc = 0;
  int packSize = 0;
  int size = 0;
  Uint8List nameBytes = Uint8List(0);
  Uint8List comment = Uint8List(0);
  int internalAttr = 0;
  int externalAttr = 0;
  int localOffset = 0;
  int disk = 0;

  /// Extra fields of the local header, without the Zip64 block.
  Uint8List localExtra = Uint8List(0);

  /// Extra fields of the central directory record, without the Zip64
  /// block.
  Uint8List centralExtra = Uint8List(0);

  /// The local header has a Zip64 block with both sizes (and 0xFFFFFFFF in
  /// the size fields).
  bool localZip64 = false;

  /// Size of the local header as last written.
  int get localHeaderSize =>
      kLocalHeaderSize +
      nameBytes.length +
      localExtra.length +
      (localZip64 ? 20 : 0);

  bool get needsCentralZip64 =>
      size >= 0xFFFFFFFF || packSize >= 0xFFFFFFFF || localOffset >= 0xFFFFFFFF;
}

void _put16(Uint8List b, int o, int v) {
  b[o] = v & 0xFF;
  b[o + 1] = (v >> 8) & 0xFF;
}

/// The local header of [it]. With [descriptor] the CRC and sizes are
/// written as zeros (they follow the data).
Uint8List buildLocalHeader(ZipOutItem it, {bool zeroSizes = false}) {
  final b = Uint8List(it.localHeaderSize);
  setUint32LE(b, 0, ZipSig.local);
  _put16(b, 4, it.versionNeeded);
  _put16(b, 6, it.flags);
  _put16(b, 8, it.method);
  setUint32LE(b, 10, it.dosTime);
  setUint32LE(b, 14, zeroSizes ? 0 : it.crc);
  if (it.localZip64) {
    setUint32LE(b, 18, 0xFFFFFFFF);
    setUint32LE(b, 22, 0xFFFFFFFF);
  } else {
    setUint32LE(b, 18, zeroSizes ? 0 : it.packSize);
    setUint32LE(b, 22, zeroSizes ? 0 : it.size);
  }
  _put16(b, 26, it.nameBytes.length);
  _put16(b, 28, b.length - kLocalHeaderSize - it.nameBytes.length);
  var p = kLocalHeaderSize;
  b.setRange(p, p + it.nameBytes.length, it.nameBytes);
  p += it.nameBytes.length;
  if (it.localZip64) {
    _put16(b, p, ZipExtraId.zip64);
    _put16(b, p + 2, 16);
    setUint64LE(b, p + 4, zeroSizes ? 0 : it.size);
    setUint64LE(b, p + 12, zeroSizes ? 0 : it.packSize);
    p += 20;
  }
  b.setRange(p, p + it.localExtra.length, it.localExtra);
  return b;
}

/// The data descriptor (with its signature); 8 byte sizes when the local
/// header has a Zip64 block.
Uint8List buildDescriptor(ZipOutItem it) {
  final z64 = it.localZip64;
  final b = Uint8List(z64 ? 24 : 16);
  setUint32LE(b, 0, ZipSig.descriptor);
  setUint32LE(b, 4, it.crc);
  if (z64) {
    setUint64LE(b, 8, it.packSize);
    setUint64LE(b, 16, it.size);
  } else {
    setUint32LE(b, 8, it.packSize);
    setUint32LE(b, 12, it.size);
  }
  return b;
}

/// The central directory record of [it].
Uint8List buildCentralRecord(ZipOutItem it) {
  final z = BytesBuilder(copy: false);
  final bigSize = it.size >= 0xFFFFFFFF;
  final bigPack = it.packSize >= 0xFFFFFFFF;
  final bigOffset = it.localOffset >= 0xFFFFFFFF;
  // with a Zip64 local header the sizes go to the Zip64 block too, which
  // some readers expect
  final z64Sizes = bigSize || bigPack || it.localZip64;
  if (z64Sizes || bigOffset) {
    final n = (z64Sizes ? 16 : 0) + (bigOffset ? 8 : 0);
    final e = Uint8List(4 + n);
    _put16(e, 0, ZipExtraId.zip64);
    _put16(e, 2, n);
    var p = 4;
    if (z64Sizes) {
      setUint64LE(e, p, it.size);
      setUint64LE(e, p + 8, it.packSize);
      p += 16;
    }
    if (bigOffset) setUint64LE(e, p, it.localOffset);
    z.add(e);
  }
  z.add(it.centralExtra);
  final extra = z.takeBytes();
  final b = Uint8List(kCentralHeaderSize +
      it.nameBytes.length +
      extra.length +
      it.comment.length);
  setUint32LE(b, 0, ZipSig.central);
  _put16(b, 4, it.versionMadeBy);
  _put16(b, 6, it.versionNeeded);
  _put16(b, 8, it.flags);
  _put16(b, 10, it.method);
  setUint32LE(b, 12, it.dosTime);
  setUint32LE(b, 16, it.crc);
  setUint32LE(b, 20, z64Sizes ? 0xFFFFFFFF : it.packSize);
  setUint32LE(b, 24, z64Sizes ? 0xFFFFFFFF : it.size);
  _put16(b, 28, it.nameBytes.length);
  _put16(b, 30, extra.length);
  _put16(b, 32, it.comment.length);
  _put16(b, 34, it.disk);
  _put16(b, 36, it.internalAttr);
  setUint32LE(b, 38, it.externalAttr);
  setUint32LE(b, 42, bigOffset ? 0xFFFFFFFF : it.localOffset);
  var p = kCentralHeaderSize;
  b.setRange(p, p + it.nameBytes.length, it.nameBytes);
  p += it.nameBytes.length;
  b.setRange(p, p + extra.length, extra);
  p += extra.length;
  b.setRange(p, p + it.comment.length, it.comment);
  return b;
}

/// Writes the end records after a central directory of [numEntries]
/// records, [cdSize] bytes at [cdOffset], the end records starting at
/// [endPos]. Zip64 records are added when a value does not fit (or when
/// [forceZip64]).
void writeEndRecords(OutStream out, int numEntries, int cdOffset, int cdSize,
    int endPos, Uint8List comment,
    {bool forceZip64 = false, int versionMadeBy = 45}) {
  final z64 = forceZip64 ||
      numEntries >= 0xFFFF ||
      cdSize >= 0xFFFFFFFF ||
      cdOffset >= 0xFFFFFFFF;
  if (z64) {
    final r = Uint8List(kZip64EocdSize);
    setUint32LE(r, 0, ZipSig.zip64Eocd);
    setUint64LE(r, 4, kZip64EocdSize - 12);
    _put16(r, 12, versionMadeBy);
    _put16(r, 14, 45);
    setUint32LE(r, 16, 0);
    setUint32LE(r, 20, 0);
    setUint64LE(r, 24, numEntries);
    setUint64LE(r, 32, numEntries);
    setUint64LE(r, 40, cdSize);
    setUint64LE(r, 48, cdOffset);
    out.write(r, 0, r.length);
    final l = Uint8List(kZip64LocatorSize);
    setUint32LE(l, 0, ZipSig.zip64Locator);
    setUint32LE(l, 4, 0);
    setUint64LE(l, 8, endPos);
    setUint32LE(l, 16, 1);
    out.write(l, 0, l.length);
  }
  final e = Uint8List(kEocdSize + comment.length);
  setUint32LE(e, 0, ZipSig.eocd);
  final n = numEntries >= 0xFFFF ? 0xFFFF : numEntries;
  _put16(e, 8, n);
  _put16(e, 10, n);
  setUint32LE(e, 12, cdSize >= 0xFFFFFFFF ? 0xFFFFFFFF : cdSize);
  setUint32LE(e, 16, cdOffset >= 0xFFFFFFFF ? 0xFFFFFFFF : cdOffset);
  _put16(e, 20, comment.length);
  e.setRange(kEocdSize, e.length, comment);
  out.write(e, 0, e.length);
}

/// Builds an NTFS extra field (0x000a) with the three times (0 for a time
/// that is not stored).
Uint8List buildNtfsExtra(int mTime, int aTime, int cTime) {
  final b = Uint8List(36);
  _put16(b, 0, ZipExtraId.ntfs);
  _put16(b, 2, 32);
  // 4 reserved bytes, then attribute tag 1 of 24 bytes
  _put16(b, 8, 1);
  _put16(b, 10, 24);
  setUint64LE(b, 12, mTime);
  setUint64LE(b, 20, aTime);
  setUint64LE(b, 28, cTime);
  return b;
}

/// Builds the WinZip AES extra field (0x9901).
Uint8List buildAesExtra(int vendorVersion, int strength, int method) {
  final b = Uint8List(11);
  _put16(b, 0, ZipExtraId.aes);
  _put16(b, 2, 7);
  _put16(b, 4, vendorVersion);
  b[6] = 0x41; // 'A'
  b[7] = 0x45; // 'E'
  b[8] = strength;
  _put16(b, 9, method);
  return b;
}

/// Removes the blocks with [id] from the extra fields [extra].
Uint8List removeExtraBlock(Uint8List extra, int id) {
  final z = BytesBuilder(copy: false);
  var p = 0;
  while (p + 4 <= extra.length) {
    final bid = extra[p] | (extra[p + 1] << 8);
    final sz = extra[p + 2] | (extra[p + 3] << 8);
    if (p + 4 + sz > extra.length) break;
    if (bid != id) z.add(Uint8List.sublistView(extra, p, p + 4 + sz));
    p += 4 + sz;
  }
  return z.takeBytes();
}
