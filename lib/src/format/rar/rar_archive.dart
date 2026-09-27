// The state of an opened RAR archive: its volumes, items and archive
// properties, filled by rar4_in.dart or rar5_in.dart.

import 'dart:typed_data';

import '../../crypto/rar3_kdf.dart';
import '../../crypto/rar5_kdf.dart';
import '../../io/streams.dart';
import 'rar_item.dart';

/// Gives the stream of the volume called [name], or null.
typedef RarVolumeOpener = SeekableInStream? Function(String name);

/// Gives the password, or throws to abort.
typedef RarPasswordGetter = String? Function();

final class RarArchiveData {
  final bool isRar5;
  RarArchiveData(this.isRar5);

  final List<SeekableInStream> volumes = [];
  final List<String> volumeNames = [];

  /// The physical size of each volume (up to its end of archive header).
  final List<int> volumeSizes = [];
  final List<RarItem> items = [];

  /// Offset of the signature in the first volume (SFX stub size).
  int sfxSize = 0;

  /// Main header flags.
  int mainFlags = 0;
  bool solid = false;
  bool isVolume = false;
  bool firstVolume = false;
  bool newNumbering = false;
  bool locked = false;
  bool recovery = false;
  bool encryptedHeaders = false;

  /// Volume number of the first opened volume (RAR5 main header, RAR4
  /// end of archive header), -1 when unknown.
  int volumeNumber = -1;

  String? comment;
  int numBlocks = 0;

  bool unexpectedEnd = false;
  bool headersError = false;
  bool unsupportedFeature = false;

  /// End of the last archive header of the first volume.
  int phySize = 0;

  // RAR5 encrypted headers
  Rar5CryptInfo? headerCrypt;
  Rar5Keys? headerKeys;

  /// The password given at open (for the data of encrypted files).
  String? password;
  bool passwordAsked = false;

  /// RAR4 encryption version (MHD_ENCRYPTVER).
  int encryptVer = 0;

  /// Derived keys by salt and KDF count (hex of salt + count).
  final Map<String, Rar5Keys> keyCache = {};

  Rar5Keys keysFor(String password, Uint8List salt, int kdfCount) {
    final k = StringBuffer();
    for (final b in salt) {
      k.write(b.toRadixString(16).padLeft(2, '0'));
    }
    k.write(':$kdfCount:$password');
    return keyCache.putIfAbsent(
        k.toString(), () => Rar5Keys.derive(password, salt, kdfCount));
  }

  /// RAR 3.x keys by salt (hex of salt + password).
  final Map<String, Rar3Keys> rar3KeyCache = {};

  Rar3Keys rar3KeysFor(String password, Uint8List? salt) {
    final k = StringBuffer();
    for (final b in salt ?? const <int>[]) {
      k.write(b.toRadixString(16).padLeft(2, '0'));
    }
    k.write(':$password');
    return rar3KeyCache.putIfAbsent(
        k.toString(), () => Rar3Keys.derive(password, salt));
  }
}

/// Searches [s] for [sig] from the start, up to [maxOffset] (a self
/// extracting module before the archive). Returns the offset or -1.
int rarFindSignature(SeekableInStream s, List<int> sig, int maxOffset) {
  final len = s.length;
  final buf = Uint8List(1 << 16);
  var pos = 0;
  while (pos < len && pos <= maxOffset) {
    s.position = pos;
    final n = readFully(s, buf, 0, buf.length);
    if (n < sig.length) return -1;
    for (var i = 0; i + sig.length <= n; i++) {
      if (pos + i > maxOffset) return -1;
      if (buf[i] != sig[0]) continue;
      var ok = true;
      for (var j = 1; j < sig.length; j++) {
        if (buf[i + j] != sig[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return pos + i;
    }
    pos += n - sig.length + 1;
  }
  return -1;
}

const List<int> rar4Signature = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00];
const List<int> rar5Signature = [
  0x52,
  0x61,
  0x72,
  0x21,
  0x1A,
  0x07,
  0x01,
  0x00
];

/// The maximum size of a self extracting module searched at open.
const int rarMaxSfxSize = 1 << 22;

/// Whether the stream starts like an executable (a possible SFX).
bool rarLooksLikeExe(SeekableInStream s) {
  final b = Uint8List(4);
  s.position = 0;
  if (readFully(s, b, 0, 4) < 4) return false;
  return (b[0] == 0x4D && b[1] == 0x5A) ||
      (b[0] == 0x7F && b[1] == 0x45 && b[2] == 0x4C && b[3] == 0x46);
}
