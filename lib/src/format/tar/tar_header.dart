// Tar header fields and number codings shared by the tar reader and writer.
//
// Ported from libarchive (BSD 2-clause, see LICENSE):
// archive_read_support_format_tar.c (tar_atol, tar_atol8, tar_atol10,
// tar_atol256, checksum, archive_block_is_null, validate_number_field,
// archive_read_format_tar_bid, pax_time) and archive_write_set_format_ustar.c,
// archive_write_set_format_gnutar.c and archive_write_set_format_pax.c
// (format_number, format_octal, format_256, add_pax_attr_binary,
// add_pax_attr_time, has_non_ASCII). Field offsets follow the POSIX ustar
// header (IEEE Std 1003.1) and the GNU tar header (tar.5 of libarchive).

import 'dart:convert';
import 'dart:typed_data';

/// Size of a tar record (header or data block).
const int kTarBlockSize = 512;

/// struct archive_entry_header_ustar / archive_entry_header_gnutar offsets.
abstract final class TarHeader {
  static const nameOffset = 0;
  static const nameSize = 100;
  static const modeOffset = 100;
  static const uidOffset = 108;
  static const gidOffset = 116;
  static const sizeOffset = 124;
  static const mtimeOffset = 136;
  static const checksumOffset = 148;
  static const typeflagOffset = 156;
  static const linknameOffset = 157;
  static const linknameSize = 100;
  static const magicOffset = 257;
  static const versionOffset = 263;
  static const unameOffset = 265;
  static const unameSize = 32;
  static const gnameOffset = 297;
  static const gnameSize = 32;
  static const rdevmajorOffset = 329;
  static const rdevminorOffset = 337;
  // ustar only
  static const prefixOffset = 345;
  static const prefixSize = 155;
  // GNU only
  static const atimeOffset = 345;
  static const ctimeOffset = 357;
  static const gnuSparseOffset = 386; // 4 x (offset[12], numbytes[12])
  static const gnuIsExtendedOffset = 482;
  static const gnuRealSizeOffset = 483;
}

/// Type flags (tar.5).
abstract final class TarType {
  static const regular = 0x30; // '0'
  static const regularOld = 0; // NUL
  static const hardLink = 0x31; // '1'
  static const symLink = 0x32; // '2'
  static const charDevice = 0x33; // '3'
  static const blockDevice = 0x34; // '4'
  static const directory = 0x35; // '5'
  static const fifo = 0x36; // '6'
  static const contiguous = 0x37; // '7'
  static const solarisAcl = 0x41; // 'A'
  static const gnuDumpDir = 0x44; // 'D'
  static const gnuLongLink = 0x4B; // 'K'
  static const gnuLongName = 0x4C; // 'L'
  static const gnuMultiVolume = 0x4D; // 'M'
  static const gnuOldLongName = 0x4E; // 'N'
  static const gnuSparse = 0x53; // 'S'
  static const gnuVolume = 0x56; // 'V'
  static const paxSun = 0x58; // 'X'
  static const paxGlobal = 0x67; // 'g'
  static const paxLocal = 0x78; // 'x'
}

/// S_IF* file type bits of st_mode.
abstract final class PosixMode {
  static const typeMask = 0xF000;
  static const fifo = 0x1000;
  static const charDevice = 0x2000;
  static const directory = 0x4000;
  static const blockDevice = 0x6000;
  static const regular = 0x8000;
  static const symLink = 0xA000;
  static const socket = 0xC000;
}

/// The header variants the reader recognizes (the archive_format values of
/// libarchive's tar reader).
enum TarFormat { v7, ustar, gnu, pax }

// archive_block_is_null
bool tarBlockIsNull(Uint8List p, [int off = 0]) {
  for (var i = 0; i < kTarBlockSize; i++) {
    if (p[off + i] != 0) return false;
  }
  return true;
}

const int _int64Max = 0x7FFFFFFFFFFFFFFF;
const int _int64Min = -0x8000000000000000;

// tar_atol_base_n
int tarAtolBaseN(Uint8List p, int off, int charCnt, int base) {
  while (charCnt != 0 && (p[off] == 0x20 || p[off] == 0x09)) {
    off++;
    charCnt--;
  }
  var sign = 1;
  if (charCnt != 0 && p[off] == 0x2D) {
    sign = -1;
    off++;
    charCnt--;
  }
  var l = 0;
  final limit = _int64Max ~/ base;
  while (charCnt != 0) {
    final digit = p[off] - 0x30;
    if (digit < 0 || digit >= base) break;
    // archive_ckd_mul_i64 / archive_ckd_add_i64: truncate on overflow
    if (l > limit || (l == limit && digit > _int64Max - limit * base)) {
      return sign < 0 ? _int64Min : _int64Max;
    }
    l = l * base + digit;
    off++;
    charCnt--;
  }
  return sign * l;
}

// tar_atol8
int tarAtol8(Uint8List p, int off, int n) => tarAtolBaseN(p, off, n, 8);

// tar_atol10
int tarAtol10(Uint8List p, int off, int n) => tarAtolBaseN(p, off, n, 10);

// tar_atol256
int tarAtol256(Uint8List p, int off, int charCnt) {
  var c = p[off];
  int neg;
  var l = 0;
  if ((c & 0x40) != 0) {
    neg = 0xFF;
    c |= 0x80;
    l = -1;
  } else {
    neg = 0;
    c &= 0x7F;
  }
  while (charCnt > 8) {
    --charCnt;
    if (c != neg) return neg != 0 ? _int64Min : _int64Max;
    c = p[++off];
  }
  if (((c ^ neg) & 0x80) != 0) return neg != 0 ? _int64Min : _int64Max;
  while (--charCnt > 0) {
    l = (l << 8) | c;
    c = p[++off];
  }
  l = (l << 8) | c;
  return l;
}

// tar_atol: base-256 when the high bit of the first byte is set, else octal
int tarAtol(Uint8List p, int off, int n) =>
    (p[off] & 0x80) != 0 ? tarAtol256(p, off, n) : tarAtol8(p, off, n);

// checksum: true when the header checksum matches, with unsigned bytes (POSIX)
// or with signed bytes (old BSD, Solaris and HP-UX tars).
bool tarChecksumOk(Uint8List h, [int off = 0]) {
  for (var i = 0; i < 8; i++) {
    final c = h[off + TarHeader.checksumOffset + i];
    if (c != 0x20 && c != 0 && (c < 0x30 || c > 0x37)) return false;
  }
  final sum = tarAtol(h, off + TarHeader.checksumOffset, 8);
  var check = 0;
  var checkSigned = 0;
  for (var i = 0; i < kTarBlockSize; i++) {
    int b;
    if (i >= 148 && i < 156) {
      b = 32;
      check += b;
      checkSigned += b;
      continue;
    }
    b = h[off + i];
    check += b;
    checkSigned += b >= 128 ? b - 256 : b;
  }
  return sum == check || sum == checkSigned;
}

// validate_number_field
bool _validateNumberField(Uint8List p, int off, int size) {
  final marker = p[off];
  if (marker == 128 || marker == 255 || marker == 0) return true;
  var i = 0;
  while (i < size && p[off + i] == 0x20) {
    i++;
  }
  while (i < size && p[off + i] >= 0x30 && p[off + i] <= 0x37) {
    i++;
  }
  while (i < size) {
    if (p[off + i] != 0x20 && p[off + i] != 0) return false;
    i++;
  }
  return true;
}

bool _bytesEqual(Uint8List p, int off, List<int> s) {
  for (var i = 0; i < s.length; i++) {
    if (p[off + i] != s[i]) return false;
  }
  return true;
}

const List<int> kUstarMagic = [0x75, 0x73, 0x74, 0x61, 0x72, 0]; // "ustar\0"
const List<int> kUstarVersion = [0x30, 0x30]; // "00"
const List<int> kGnuMagic = [0x75, 0x73, 0x74, 0x61, 0x72, 0x20, 0x20, 0];

/// true when the block at [off] has the GNU magic "ustar  \0".
bool tarIsGnuMagic(Uint8List h, [int off = 0]) =>
    _bytesEqual(h, off + TarHeader.magicOffset, kGnuMagic);

/// true when the block at [off] starts its magic with "ustar".
bool tarIsUstarMagic(Uint8List h, [int off = 0]) => _bytesEqual(
    h, off + TarHeader.magicOffset, const [0x75, 0x73, 0x74, 0x61, 0x72]);

// archive_read_format_tar_bid: 0 when the 512 bytes at [off] can not start a
// tar archive, else the number of bits verified (10 for an end marker).
int tarBid(Uint8List h, [int off = 0]) {
  if (h[off] == 0 && tarBlockIsNull(h, off)) return 10;
  if (!tarChecksumOk(h, off)) return 0;
  var bid = 48;
  if (_bytesEqual(h, off + TarHeader.magicOffset, kUstarMagic) &&
      _bytesEqual(h, off + TarHeader.versionOffset, kUstarVersion)) {
    bid += 56;
  }
  if (_bytesEqual(h, off + TarHeader.magicOffset,
          const [0x75, 0x73, 0x74, 0x61, 0x72, 0x20]) &&
      _bytesEqual(h, off + TarHeader.versionOffset, const [0x20, 0])) {
    bid += 56;
  }
  final t = h[off + TarHeader.typeflagOffset];
  if (t != 0 &&
      !(t >= 0x30 && t <= 0x39) &&
      !(t >= 0x41 && t <= 0x5A) &&
      !(t >= 0x61 && t <= 0x7A)) {
    return 0;
  }
  bid += 2;
  if (!_validateNumberField(h, off + TarHeader.modeOffset, 8) ||
      !_validateNumberField(h, off + TarHeader.uidOffset, 8) ||
      !_validateNumberField(h, off + TarHeader.gidOffset, 8) ||
      !_validateNumberField(h, off + TarHeader.mtimeOffset, 12) ||
      !_validateNumberField(h, off + TarHeader.sizeOffset, 12) ||
      !_validateNumberField(h, off + TarHeader.rdevmajorOffset, 8) ||
      !_validateNumberField(h, off + TarHeader.rdevminorOffset, 8)) {
    bid = 0;
  }
  return bid;
}

/// IsArc_Tar for the format table: [p] holds the first [size] bytes of the
/// file. Returns k_IsArc_Res_YES (1), NO (0) or NEED_MORE (2).
int isArcTar(Uint8List p, int size) {
  if (size < kTarBlockSize) return 2;
  final bid = tarBid(p);
  // an end marker alone is not enough to claim a file
  if (bid <= 10) return 0;
  return 1;
}

// format_octal (archive_write_set_format_gnutar.c): [s] octal digits,
// negative values as 0. Returns false when the value did not fit (the field
// is then filled with '7').
bool tarFormatOctal(int v, Uint8List p, int off, int s) {
  var len = s;
  if (v < 0) v = 0;
  var q = off + s;
  while (s-- > 0) {
    p[--q] = 0x30 + (v & 7);
    v >>= 3;
  }
  if (v == 0) return true;
  q = off;
  while (len-- > 0) {
    p[q++] = 0x37;
  }
  return false;
}

// format_256
void tarFormat256(int v, Uint8List p, int off, int s) {
  var q = off + s;
  while (s-- > 0) {
    p[--q] = v & 0xFF;
    v >>= 8;
  }
  p[q] |= 0x80;
}

// format_number (archive_write_set_format_gnutar.c): octal in [s] digits
// when it fits (the terminator stays), else base-256 over [maxSize] bytes.
void tarFormatNumberGnu(int v, Uint8List p, int off, int s, int maxSize) {
  if (v >= 0 && v < (1 << (s * 3))) {
    tarFormatOctal(v, p, off, s);
    return;
  }
  tarFormat256(v, p, off, maxSize);
}

// format_number (archive_write_set_format_ustar.c, non strict): octal that
// may use the terminator bytes up to [maxSize] digits, then base-256.
void tarFormatNumberUstar(int v, Uint8List p, int off, int s, int maxSize) {
  var limit = 1 << (s * 3);
  if (v >= 0) {
    while (s <= maxSize) {
      if (v < limit) {
        tarFormatOctal(v, p, off, s);
        return;
      }
      s++;
      limit <<= 3;
    }
  }
  tarFormat256(v, p, off, maxSize);
}

/// Computes the checksum of the header block [h] and stores it the way GNU
/// tar and 7-Zip do: six octal digits, NUL, space.
void tarSetChecksum(Uint8List h) {
  for (var i = 0; i < 8; i++) {
    h[TarHeader.checksumOffset + i] = 0x20;
  }
  var checksum = 0;
  for (var i = 0; i < kTarBlockSize; i++) {
    checksum += h[i];
  }
  tarFormatOctal(checksum, h, TarHeader.checksumOffset, 6);
  h[TarHeader.checksumOffset + 6] = 0;
  h[TarHeader.checksumOffset + 7] = 0x20;
}

/// Seconds from 1601 to 1970 in FILETIME units (100 ns).
const int kUnixEpochFileTime = 116444736000000000;

/// FILETIME (100 ns ticks since 1601) from Unix seconds and nanoseconds.
/// [ns] has the sign of [sec] as in libarchive (-1.2 s is sec -1, ns 2e8).
int tarTimeToFileTime(int sec, int ns) {
  final frac = ns ~/ 100;
  return sec * 10000000 + (sec < 0 ? -frac : frac) + kUnixEpochFileTime;
}

/// (seconds, nanoseconds) since 1970 of the FILETIME [ft], rounded down.
(int, int) fileTimeToTarTime(int ft) {
  final t = ft - kUnixEpochFileTime;
  var sec = t ~/ 10000000;
  var rem = t - sec * 10000000;
  if (rem < 0) {
    sec--;
    rem += 10000000;
  }
  return (sec, rem * 100);
}

// pax_time: parses "[-]sec[.frac]"; null on a syntax error or overflow.
(int, int)? tarPaxTime(Uint8List p, int off, int length) {
  if (length <= 0) return (0, 0);
  var s = 0;
  var sign = 1;
  if (p[off] == 0x2D) {
    sign = -1;
    off++;
    length--;
  }
  while (length > 0 && p[off] >= 0x30 && p[off] <= 0x39) {
    final digit = p[off] - 0x30;
    if (s > (_int64Max - digit) ~/ 10) return null;
    s = s * 10 + digit;
    ++off;
    --length;
  }
  final sec = s * sign;
  var n = 0;
  if (length <= 0) return (sec, 0);
  if (p[off] != 0x2E) return null;
  ++off;
  --length;
  var l = 100000000;
  do {
    if (length <= 0) return (sec, n);
    final c = p[off];
    if (c < 0x30 || c > 0x39) return null;
    n += (c - 0x30) * l;
    ++off;
    --length;
    l ~/= 10;
  } while (l != 0);
  while (length > 0) {
    final c = p[off];
    if (c < 0x30 || c > 0x39) return null;
    ++off;
    --length;
  }
  return (sec, n);
}

/// Decodes a header string: UTF-8 when it is valid UTF-8 (the pax default
/// and what 7-Zip, GNU tar and libarchive write on Linux), else Latin-1 so
/// that every byte keeps a character.
String tarDecodeString(Uint8List p, int off, int len) {
  final bytes = Uint8List.sublistView(p, off, off + len);
  var ascii = true;
  for (final b in bytes) {
    if (b >= 0x80) {
      ascii = false;
      break;
    }
  }
  if (ascii) return String.fromCharCodes(bytes);
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes);
  } on FormatException {
    return latin1.decode(bytes);
  }
}

/// Length of the NUL terminated string in the field [off, off + size).
int tarStrLen(Uint8List p, int off, int size) {
  var n = 0;
  while (n < size && p[off + n] != 0) {
    n++;
  }
  return n;
}

// has_non_ASCII
bool tarHasNonAscii(Uint8List s) {
  for (final b in s) {
    if (b >= 0x80) return true;
  }
  return false;
}

// add_pax_attr_binary: appends "<len> <key>=<value>\n" to [out].
void tarAddPaxAttr(BytesBuilder out, String key, List<int> value) {
  final keyBytes = ascii.encode(key);
  final len = 1 + keyBytes.length + 1 + value.length + 1;
  var nextTen = 1;
  var digits = 0;
  var i = len;
  while (i > 0) {
    i ~/= 10;
    digits++;
    nextTen *= 10;
  }
  if (len + digits >= nextTen) digits++;
  out.add(ascii.encode('${len + digits} '));
  out.add(keyBytes);
  out.addByte(0x3D);
  out.add(value);
  out.addByte(0x0A);
}

// add_pax_attr_int
void tarAddPaxAttrInt(BytesBuilder out, String key, int value) =>
    tarAddPaxAttr(out, key, ascii.encode('$value'));

// add_pax_attr_time: seconds with the fraction of [ns] limited to
// [numDigits] digits (0 to 9), trailing zeros removed.
void tarAddPaxAttrTime(
    BytesBuilder out, String key, int sec, int ns, int numDigits) {
  final sb = StringBuffer();
  if (sec < 0 && ns != 0) {
    // libarchive assumes nanos with the sign of sec: -1.2 is (-1, 2e8)
    sb.write('-${-sec}');
  } else {
    sb.write('$sec');
  }
  if (numDigits > 0 && ns != 0) {
    var frac = ns.toString().padLeft(9, '0').substring(0, numDigits);
    var end = frac.length;
    while (end > 0 && frac.codeUnitAt(end - 1) == 0x30) {
      end--;
    }
    frac = frac.substring(0, end);
    if (frac.isNotEmpty) sb.write('.$frac');
  }
  tarAddPaxAttr(out, key, ascii.encode(sb.toString()));
}
