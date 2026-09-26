// 7zAES (AES-256-CBC with a SHA-256 based key derivation): port of
// CPP/7zip/Crypto/7zAes.cpp.
//
// The key is SHA-256 over 2^NumCyclesPower repetitions of
// (salt + password as UTF-16LE + 64-bit little endian counter).
// Coder properties:
//   byte 0: NumCyclesPower | (salt present << 7) | (iv present << 6)
//   byte 1: ((saltSize - 1) << 4) | (ivSize - 1), when salt or iv is present
//   then the salt and the iv bytes.

import 'dart:math';
import 'dart:typed_data';

import '../codec/codec.dart';
import '../codec/filters/filter_coder.dart';
import '../io/streams.dart';
import 'aes.dart';
import 'sha256.dart';

/// kKeySize
const int kSevenZipAesKeySize = 32;

/// kSaltSizeMax
const int kSevenZipAesSaltSizeMax = 16;

/// kIvSizeMax
const int kSevenZipAesIvSizeMax = 16;

/// k_NumCyclesPower_Supported_MAX
const int _kNumCyclesPowerSupportedMax = 24;

/// The NumCyclesPower 7-Zip uses for encryption (CEncoder::CEncoder).
const int kSevenZipAesDefaultNumCyclesPower = 19;

/// The password as 7-Zip passes it to CryptoSetPassword: UTF-16LE, two
/// bytes per UTF-16 code unit (7zDecode.cpp, 7zEncode.cpp).
Uint8List sevenZipPasswordBytes(String password) {
  final units = password.codeUnits;
  final out = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    out[i * 2] = units[i];
    out[i * 2 + 1] = units[i] >> 8;
  }
  return out;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// CKeyInfo
class KeyInfo {
  int numCyclesPower = 0;
  int saltSize = 0;
  final Uint8List salt = Uint8List(kSevenZipAesSaltSizeMax);
  Uint8List password = Uint8List(0);
  final Uint8List key = Uint8List(kSevenZipAesKeySize);

  KeyInfo();

  KeyInfo._copy(KeyInfo o)
      : numCyclesPower = o.numCyclesPower,
        saltSize = o.saltSize,
        password = Uint8List.fromList(o.password) {
    salt.setAll(0, o.salt);
    key.setAll(0, o.key);
  }

  // CKeyInfo::ClearProps
  void clearProps() {
    numCyclesPower = 0;
    saltSize = 0;
    salt.fillRange(0, salt.length, 0);
  }

  // CKeyInfo::IsEqualTo
  bool isEqualTo(KeyInfo a) {
    if (saltSize != a.saltSize || numCyclesPower != a.numCyclesPower) {
      return false;
    }
    for (var i = 0; i < saltSize; i++) {
      if (salt[i] != a.salt[i]) return false;
    }
    return _bytesEqual(password, a.password);
  }

  // CKeyInfo::CalcKey
  void calcKey() {
    if (numCyclesPower == 0x3F) {
      var pos = 0;
      for (; pos < saltSize; pos++) {
        key[pos] = salt[pos];
      }
      for (var i = 0; i < password.length && pos < kSevenZipAesKeySize; i++) {
        key[pos++] = password[i];
      }
      for (; pos < kSevenZipAesKeySize; pos++) {
        key[pos] = 0;
      }
      return;
    }
    const kUnrPow = 6;
    final numUnroll =
        1 << (numCyclesPower <= kUnrPow ? numCyclesPower : kUnrPow);
    final bufSize = 8 + saltSize + password.length;
    final unrollSize = bufSize * numUnroll;
    final buf = Uint8List(unrollSize);
    buf.setRange(0, saltSize, salt);
    buf.setRange(saltSize, saltSize + password.length, password);
    // The 8 counter bytes at the end of each copy start as zeros.
    for (var i = 1; i < numUnroll; i++) {
      buf.setRange(i * bufSize, (i + 1) * bufSize, buf);
    }

    final sha = Sha256();
    final numRounds = 1 << numCyclesPower;
    var r = 0;
    do {
      // Only the low 32 bits of the counter change (numCyclesPower <= 24).
      var dest = bufSize - 8;
      var i = r;
      r += numUnroll;
      do {
        buf[dest] = i;
        buf[dest + 1] = i >> 8;
        buf[dest + 2] = i >> 16;
        buf[dest + 3] = i >> 24;
        i++;
        dest += bufSize;
      } while (i < r);
      sha.update(buf, 0, unrollSize);
    } while (r < numRounds);
    sha.finalTo(key);
    buf.fillRange(0, unrollSize, 0);
  }
}

/// CKeyInfoCache
class KeyInfoCache {
  final int size;
  final List<KeyInfo> _keys = [];
  KeyInfoCache(this.size);

  // CKeyInfoCache::GetKey
  bool getKey(KeyInfo key) {
    for (var i = 0; i < _keys.length; i++) {
      final cached = _keys[i];
      if (key.isEqualTo(cached)) {
        key.key.setAll(0, cached.key);
        if (i != 0) _keys.insert(0, _keys.removeAt(i));
        return true;
      }
    }
    return false;
  }

  // CKeyInfoCache::FindAndAdd
  void findAndAdd(KeyInfo key) {
    for (var i = 0; i < _keys.length; i++) {
      if (key.isEqualTo(_keys[i])) {
        if (i != 0) _keys.insert(0, _keys.removeAt(i));
        return;
      }
    }
    add(key);
  }

  // CKeyInfoCache::Add
  void add(KeyInfo key) {
    if (_keys.length >= size) _keys.removeLast();
    _keys.insert(0, KeyInfo._copy(key));
  }

  void clear() => _keys.clear();
}

/// g_GlobalKeyCache (one per isolate here).
final KeyInfoCache globalKeyCache = KeyInfoCache(32);

/// Derives the 7zAES key (CKeyInfo::CalcKey) without the caches.
/// [password] is the UTF-16LE form (see [sevenZipPasswordBytes]).
Uint8List sevenZipAesDeriveKey(
    Uint8List salt, Uint8List password, int numCyclesPower) {
  final k = KeyInfo()
    ..numCyclesPower = numCyclesPower
    ..saltSize = salt.length
    ..password = password;
  k.salt.setAll(0, salt);
  k.calcKey();
  return Uint8List.fromList(k.key);
}

/// CBase + CBaseCoder: the 7zAES ICompressFilter.
class SevenZipAesCoder implements CompressFilter {
  final KeyInfoCache _cachedKeys = KeyInfoCache(16);
  final KeyInfo _key = KeyInfo();
  final Uint8List _iv = Uint8List(kSevenZipAesIvSizeMax);
  int _ivSize = 0;
  final AesCbcFilter _aesFilter;

  SevenZipAesCoder._(bool encodeMode)
      : _aesFilter = AesCbcFilter(encodeMode, kSevenZipAesKeySize);

  /// The 7zAES decoder (CDecoder).
  SevenZipAesCoder.decoder() : this._(false);

  /// The 7zAES encoder (CEncoder): NumCyclesPower 19, no salt.
  SevenZipAesCoder.encoder() : _aesFilter = AesCbcFilter(true) {
    _key.numCyclesPower = kSevenZipAesDefaultNumCyclesPower;
  }

  /// The derived key (valid after [init]).
  Uint8List get key => _key.key;

  // CBase::PrepareKey
  void _prepareKey() {
    var found = false;
    if (!_cachedKeys.getKey(_key)) {
      found = globalKeyCache.getKey(_key);
      if (!found) _key.calcKey();
      _cachedKeys.add(_key);
    }
    if (!found) globalKeyCache.findAndAdd(_key);
  }

  // CEncoder::ResetInitVector
  void resetInitVector([Random? random]) {
    _iv.fillRange(0, _iv.length, 0);
    _ivSize = 16;
    final rnd = random ?? Random.secure();
    for (var i = 0; i < _ivSize; i++) {
      _iv[i] = rnd.nextInt(256);
    }
  }

  /// Sets the IV directly (for tests and reproducible output).
  void setInitVector(Uint8List iv) {
    if (iv.length > kSevenZipAesIvSizeMax) {
      throw ArgumentError('IV is too long');
    }
    _iv.fillRange(0, _iv.length, 0);
    _iv.setRange(0, iv.length, iv);
    _ivSize = iv.length;
  }

  /// Sets NumCyclesPower (encoder side), 0..24 or 0x3F.
  set numCyclesPower(int v) {
    if (!(v <= _kNumCyclesPowerSupportedMax || v == 0x3F) || v < 0) {
      throw ArgumentError('Unsupported NumCyclesPower: $v');
    }
    _key.numCyclesPower = v;
  }

  // CEncoder::WriteCoderProperties
  Uint8List writeCoderProperties() {
    final props =
        Uint8List(2 + kSevenZipAesSaltSizeMax + kSevenZipAesIvSizeMax);
    var propsSize = 1;
    props[0] = _key.numCyclesPower |
        (_key.saltSize == 0 ? 0 : (1 << 7)) |
        (_ivSize == 0 ? 0 : (1 << 6));
    if (_key.saltSize != 0 || _ivSize != 0) {
      props[1] = ((_key.saltSize == 0 ? 0 : _key.saltSize - 1) << 4) |
          (_ivSize == 0 ? 0 : _ivSize - 1);
      props.setRange(2, 2 + _key.saltSize, _key.salt);
      propsSize = 2 + _key.saltSize;
      props.setRange(propsSize, propsSize + _ivSize, _iv);
      propsSize += _ivSize;
    }
    return Uint8List.sublistView(props, 0, propsSize);
  }

  // CDecoder::SetDecoderProperties2. Throws SevenZipException
  // (unsupportedMethod) for E_INVALIDARG and E_NOTIMPL, as 7zDecode.cpp
  // maps both to E_NOTIMPL.
  void setDecoderProperties2(Uint8List data) {
    _key.clearProps();
    _ivSize = 0;
    _iv.fillRange(0, _iv.length, 0);
    final size = data.length;
    if (size == 0) return;
    final b0 = data[0];
    _key.numCyclesPower = b0 & 0x3F;
    if ((b0 & 0xC0) == 0) {
      if (size == 1) return;
      throw _badProps;
    }
    if (size <= 1) throw _badProps;
    final b1 = data[1];
    final saltSize = ((b0 >> 7) & 1) + (b1 >> 4);
    final ivSize = ((b0 >> 6) & 1) + (b1 & 0x0F);
    if (size != 2 + saltSize + ivSize) throw _badProps;
    _key.saltSize = saltSize;
    var p = 2;
    for (var i = 0; i < saltSize; i++) {
      _key.salt[i] = data[p++];
    }
    for (var i = 0; i < ivSize; i++) {
      _iv[i] = data[p++];
    }
    _ivSize = ivSize;
    if (!(_key.numCyclesPower <= _kNumCyclesPowerSupportedMax ||
        _key.numCyclesPower == 0x3F)) {
      throw const SevenZipException(
          '7zAES: unsupported NumCyclesPower', SevenZipError.unsupportedMethod);
    }
  }

  static const _badProps = SevenZipException(
      '7zAES: invalid properties', SevenZipError.unsupportedMethod);

  // CBaseCoder::CryptoSetPassword. [data] is the UTF-16LE password.
  void cryptoSetPassword(Uint8List data) {
    _key.password.fillRange(0, _key.password.length, 0);
    _key.password = Uint8List.fromList(data);
  }

  // CBaseCoder::Init
  @override
  void init() {
    _prepareKey();
    _aesFilter.setKey(_key.key);
    _aesFilter.setInitVector(_iv);
    _aesFilter.init();
  }

  // CBaseCoder::Filter
  @override
  int filter(Uint8List data, int off, int size) =>
      _aesFilter.filter(data, off, size);
}

/// DecoderFactory for MethodId.aes. The key is derived here (it can take a
/// few hundred milliseconds), so a missing password fails early.
///
/// A missing password (no provider, or the provider returns null) throws
/// [SevenZipException] with [SevenZipError.wrongPassword]. AES-CBC has no
/// check value: like 7-Zip, a wrong password shows up later as a data or
/// CRC error of the next coder, which the archive handler reports as a
/// possibly wrong password for encrypted folders.
InStream sevenZipAesDecoderFactory(
    Uint8List props, List<InStream> inputs, int? outSize, CoderContext ctx) {
  if (inputs.length != 1) {
    throw const SevenZipException(
        'Wrong number of coder streams', SevenZipError.unsupportedMethod);
  }
  final coder = SevenZipAesCoder.decoder();
  coder.setDecoderProperties2(props);
  final provider = ctx.password;
  final password = provider?.call();
  if (password == null) {
    throw const SevenZipException(
        'A password is required', SevenZipError.wrongPassword);
  }
  coder.cryptoSetPassword(sevenZipPasswordBytes(password));
  return FilterReader(inputs[0], coder, outSize: outSize);
}

/// Registers the 7zAES decoder.
void registerCryptoCodecs(Map<int, DecoderFactory> reg) {
  reg[MethodId.aes] = sevenZipAesDecoderFactory;
}

/// The 7zAES encoder as a [PushEncoder] (CEncoder driven by CFilterCoder in
/// write mode). Plain data written to it is encrypted to [output]; [close]
/// pads the last block with zeros like 7-Zip.
///
/// The IV is 16 random bytes from Random.secure (ResetInitVector) unless
/// [iv] is given; NumCyclesPower is 19 and there is no salt, as in 7-Zip.
class SevenZipAesEncoder implements PushEncoder {
  final SevenZipAesCoder _coder;
  late final FilterWriter _writer;
  @override
  late final Uint8List props;

  SevenZipAesEncoder(OutStream output, String password,
      {int numCyclesPower = kSevenZipAesDefaultNumCyclesPower,
      Uint8List? iv,
      Random? random})
      : _coder = SevenZipAesCoder.encoder() {
    _coder.numCyclesPower = numCyclesPower;
    if (iv != null) {
      _coder.setInitVector(iv);
    } else {
      _coder.resetInitVector(random);
    }
    _coder.cryptoSetPassword(sevenZipPasswordBytes(password));
    props = Uint8List.fromList(_coder.writeCoderProperties());
    _writer = FilterWriter(output, _coder, encodeMode: true, bufSize: 1 << 16);
  }

  /// Number of encrypted bytes written to the output so far.
  int get outSize => _writer.outSize;

  @override
  void write(Uint8List buf, int off, int len) => _writer.write(buf, off, len);

  @override
  void flush() => _writer.flush();

  @override
  void close() => _writer.finish();
}
