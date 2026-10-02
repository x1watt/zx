// Signed generations (docs/zx-format.md, section "Seals"): an optional
// chain of hashes over the stored bytes of each generation, signed with a
// NOSTR key (BIP-340), with a policy that names the admin and the
// maintainers allowed to sign. Nothing stops someone who holds the file
// from changing it; the seals make every change visible to any reader,
// without the password of an encrypted archive.
//
// A generation that is sealed ends with: Index, Seal, Footer (the Footer's
// seal_size tells where the Seal starts). The Seal holds:
//   - the generation number and data_start (the end of the previous
//     Footer, 0 for the first generation);
//   - data_hash: SHA-256 over the piece digests of the stored bytes in
//     [data_start, index_offset): the archive Header (in the first
//     generation) and every block, each piece digest being
//     SHA-256(block header || SHA-256(payload but its last 32 bytes) ||
//     its last 32 bytes), so that the block workers hash the payloads in
//     parallel and the MAC of an encrypted block (written last) is a tail;
//   - index_hash: SHA-256 of the stored Index bytes;
//   - prev_root: the root of the previous generation's Seal (zero for an
//     activation, which instead holds prefix_hash, the SHA-256 of every
//     byte before data_start);
//   - the policy (admin, maintainers, write rule, sequence, state), the
//     acceptance signature of a new admin, and the signature.
// root = SHA-256("zx/seal/1" || archive_id || the Seal's records before
// the signature); the signature is BIP-340 over root.

export 'zx_seal_types.dart';

import 'dart:typed_data';

import '../../crypto/schnorr.dart';
import '../../crypto/sha256.dart';
import '../../io/streams.dart';
import '../../util/crc32c.dart';
import 'zx_format.dart';
import 'zx_seal_types.dart';
import 'zx_reader.dart' show ZxArchiveReader;
import 'zx_writer.dart' show ZxSink;

const int zxSealMagic = 0x3153585A; // "ZXS1"

abstract final class _SealRec {
  static const chain = 0x02;
  static const genesis = 0x04;
  static const policy = 0x06;
  static const accept = 0x08;
  static const signature = 0x0A;
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final Uint8List _zero32 = Uint8List(32);

Uint8List zxPolicyEncode(ZxPolicy p) {
  final w = ZxBytes(64 + 32 * p.maintainers.length);
  w.vint(p.seq);
  w.u8(p.active ? 0 : 1);
  w.u8(p.rule.index);
  w.bytes(p.admin);
  w.vint(p.maintainers.length);
  for (final m in p.maintainers) {
    w.bytes(m);
  }
  return w.toBytes();
}

ZxPolicy zxPolicyDecode(Uint8List b) {
  final r = ZxRead(b);
  final seq = r.vint();
  final state = r.u8();
  final rule = r.u8();
  if (state > 1 || rule > 1) zxDamaged('bad seal policy');
  final admin = Uint8List.fromList(r.bytes(32));
  final n = r.count(32);
  final ms = [for (var i = 0; i < n; i++) Uint8List.fromList(r.bytes(32))];
  return ZxPolicy(admin,
      maintainers: ms,
      rule: ZxWriteRule.values[rule],
      seq: seq,
      active: state == 0);
}

/// Builds the bytes of a Seal ([ZxSeal]); signs it when [signerSecret] is given.
Uint8List zxSealBuild(
    {required Uint8List archiveId,
    required int generation,
    required int dataStart,
    required Uint8List dataHash,
    required Uint8List indexHash,
    Uint8List? prevRoot,
    Uint8List? prefixHash,
    required ZxPolicy policy,
    Uint8List? accept,
    Uint8List? signerSecret}) {
  final body = ZxBytes(256);
  body.vint(1); // version
  body.rec(_SealRec.chain, (w) {
    w.vint(generation);
    w.vint(dataStart);
    w.bytes(dataHash);
    w.bytes(indexHash);
    w.bytes(prevRoot ?? _zero32);
  });
  if (prevRoot == null) {
    body.rec(_SealRec.genesis, (w) => w.bytes(prefixHash ?? _zero32));
  }
  body.record(_SealRec.policy, zxPolicyEncode(policy));
  if (accept != null) body.record(_SealRec.accept, accept);
  final root = zxSealRoot(archiveId, body.view());
  final w = ZxBytes(body.length + 120);
  w.u32(zxSealMagic);
  w.bytes(body.view());
  if (signerSecret != null) {
    final pk = publicKeyOf(signerSecret);
    final sig = schnorrSign(signerSecret, root);
    w.rec(_SealRec.signature, (r) {
      r.bytes(pk);
      r.bytes(sig);
    });
  }
  w.u32(Crc32c.of(w.view()));
  return w.toBytes();
}

/// Parses the Seal [b] of the archive [archiveId].
ZxSeal zxSealParse(Uint8List b, Uint8List archiveId) {
  if (b.length < 12 || getUint32LE(b, 0) != zxSealMagic) {
    zxDamaged('not a seal');
  }
  final crcPos = b.length - 4;
  if (Crc32c.of(b, 0, crcPos) != getUint32LE(b, crcPos)) {
    zxDamaged('seal CRC mismatch');
  }
  final r = ZxRead(b, 4, crcPos);
  final version = r.vint();
  if (version != 1) zxDamaged('seal version $version');
  int? generation, dataStart;
  Uint8List? dataHash, indexHash, prev, prefix, accept, signer, sig;
  ZxPolicy? policy;
  var bodyEnd = crcPos;
  while (!r.atEnd) {
    final at = r.pos;
    final type = r.vint();
    final len = r.vint();
    final p = ZxRead(b, r.pos, r.pos + len);
    r.bytes(len);
    switch (type) {
      case _SealRec.chain:
        generation = p.vint();
        dataStart = p.vint();
        dataHash = Uint8List.fromList(p.bytes(32));
        indexHash = Uint8List.fromList(p.bytes(32));
        prev = Uint8List.fromList(p.bytes(32));
      case _SealRec.genesis:
        prefix = Uint8List.fromList(p.bytes(32));
      case _SealRec.policy:
        policy = zxPolicyDecode(Uint8List.sublistView(b, p.pos, p.end));
      case _SealRec.accept:
        accept = Uint8List.fromList(p.bytes(64));
      case _SealRec.signature:
        bodyEnd = at;
        signer = Uint8List.fromList(p.bytes(32));
        sig = Uint8List.fromList(p.bytes(64));
      default:
        if (type & 1 != 0) zxDamaged('unknown critical seal record $type');
    }
  }
  if (generation == null || policy == null) zxDamaged('incomplete seal');
  final root = zxSealRoot(archiveId, Uint8List.sublistView(b, 4, bodyEnd));
  return ZxSeal(generation, dataStart!, dataHash!, indexHash!,
      prefix != null ? null : prev, prefix, policy, accept, signer, sig, root);
}

Uint8List _tagged(String tag, List<Uint8List> parts) {
  final h = Sha256()..update(Uint8List.fromList(tag.codeUnits));
  for (final p in parts) {
    h.update(p);
  }
  return h.digest();
}

/// The root of a Seal: what its signature signs.
Uint8List zxSealRoot(Uint8List archiveId, Uint8List body) =>
    _tagged('zx/seal/1', [archiveId, body]);

/// The message a new admin signs to accept the role at [generation].
Uint8List zxAcceptMessage(
    Uint8List archiveId, Uint8List newAdmin, int generation) {
  final g = Uint8List(8);
  setUint64LE(g, 0, generation);
  return _tagged('zx/admin/1', [archiveId, newAdmin, g]);
}

/// The acceptance signature of the new admin [secret] for the archive
/// [archiveId] at [generation].
Uint8List zxAcceptSignature(
        Uint8List secret, Uint8List archiveId, int generation) =>
    schnorrSign(
        secret, zxAcceptMessage(archiveId, publicKeyOf(secret), generation));

// ---------------------------------------------------------------------------
// Hashing the stored bytes of a generation

/// The SHA-256 of a block payload but its last 32 bytes (the "core"
/// digest the block workers compute in parallel).
Uint8List zxPayloadCoreDigest(Uint8List payload) {
  final tail = payload.length < 32 ? payload.length : 32;
  return (Sha256()..update(payload, 0, payload.length - tail)).digest();
}

/// The data hash of a generation, fed with its stored bytes in order: the
/// first [rawPrefix] bytes (the archive Header of the first generation)
/// are one piece, then every block is a piece. Blocks whose core digest
/// is already known are given with [hint] before their payload is added.
class ZxPieceHasher {
  final Sha256 _top = Sha256();
  final Uint8List _digest = Uint8List(32);
  int _rawLeft;
  Sha256? _raw;

  // the block being read
  final Uint8List _hbuf = Uint8List(300);
  int _hlen = 0;
  ZxBlockHeader? _cur;
  int _payLeft = 0;
  int _coreLeft = 0;
  final Sha256 _core = Sha256();
  final Uint8List _tail = Uint8List(32);
  int _tailLen = 0;
  Uint8List? _knownCore;

  Uint8List? _hintPayload;
  Uint8List? _hintDigest;

  ZxPieceHasher({int rawPrefix = 0}) : _rawLeft = rawPrefix {
    if (rawPrefix > 0) _raw = Sha256();
  }

  /// The next payload added is [payload] (the same object, whole), whose
  /// core digest is [coreDigest].
  void hint(Uint8List payload, Uint8List coreDigest) {
    _hintPayload = payload;
    _hintDigest = coreDigest;
  }

  void add(Uint8List b, [int off = 0, int? end]) {
    var i = off;
    final e = end ?? b.length;
    while (i < e) {
      if (_rawLeft > 0) {
        final n = e - i < _rawLeft ? e - i : _rawLeft;
        _raw!.update(b, i, n);
        i += n;
        _rawLeft -= n;
        if (_rawLeft == 0) {
          _raw!.finalTo(_digest);
          _top.update(_digest);
          _raw = null;
        }
        continue;
      }
      final cur = _cur;
      if (cur == null) {
        // a block header: whole in the buffer before it is parsed
        final n = e - i < _hbuf.length - _hlen ? e - i : _hbuf.length - _hlen;
        _hbuf.setRange(_hlen, _hlen + n, b, i);
        final before = _hlen;
        _hlen += n;
        final h = ZxBlockHeader.tryParse(_hbuf, 0, _hlen);
        if (h == null) {
          if (_hlen == _hbuf.length) zxDamaged('seal: not a block');
          i += n;
          continue;
        }
        i += h.headerSize - before;
        _hlen = 0;
        _startBlock(h);
        continue;
      }
      // the payload of the current block
      final hp = _hintPayload;
      if (hp != null &&
          identical(hp, b) &&
          i == off &&
          _payLeft == cur.packedSize &&
          hp.length == _payLeft &&
          e - i >= hp.length) {
        _useHint(hp);
        i += hp.length;
        continue;
      }
      var n = e - i < _payLeft ? e - i : _payLeft;
      if (_coreLeft > 0) {
        final c = n < _coreLeft ? n : _coreLeft;
        _core.update(b, i, c);
        _coreLeft -= c;
        _payLeft -= c;
        i += c;
        n -= c;
      }
      if (n > 0) {
        _tail.setRange(_tailLen, _tailLen + n, b, i);
        _tailLen += n;
        _payLeft -= n;
        i += n;
      }
      if (_payLeft == 0) _endBlock();
    }
  }

  void _startBlock(ZxBlockHeader h) {
    _cur = h;
    _payLeft = h.packedSize;
    final tail = h.packedSize < 32 ? h.packedSize : 32;
    _coreLeft = h.packedSize - tail;
    _tailLen = 0;
    _knownCore = null;
    _core.init();
    _blockHeader =
        Uint8List.fromList(Uint8List.sublistView(_hbuf, 0, h.headerSize));
    if (_payLeft == 0) _endBlock();
  }

  Uint8List _blockHeader = Uint8List(0);

  void _useHint(Uint8List payload) {
    _knownCore = _hintDigest;
    _hintPayload = null;
    _hintDigest = null;
    final tail = payload.length < 32 ? payload.length : 32;
    _tail.setRange(0, tail, payload, payload.length - tail);
    _tailLen = tail;
    _coreLeft = 0;
    _payLeft = 0;
    _endBlock();
  }

  void _endBlock() {
    final core = _knownCore ?? _core.digest();
    final h = Sha256()
      ..update(_blockHeader)
      ..update(core)
      ..update(_tail, 0, _tailLen);
    h.finalTo(_digest);
    _top.update(_digest);
    _cur = null;
    _knownCore = null;
    _hintPayload = null;
    _hintDigest = null;
  }

  /// True between pieces (nothing half read).
  bool get atBoundary => _rawLeft == 0 && _cur == null && _hlen == 0;

  /// The data hash; the bytes must end at a piece boundary.
  Uint8List finish() {
    if (!atBoundary) zxDamaged('seal: the data does not end with a block');
    return _top.digest();
  }
}

// ---------------------------------------------------------------------------
// Writing

/// What a writer is asked to do about seals.
class ZxSealOptions {
  /// The secret key that signs the new generation (admin or maintainer).
  Uint8List? signer;

  /// Activates sealing (the signer becomes the admin, unless [newAdmin]).
  bool activate = false;

  /// Switches sealing off with this generation (signed by the admin).
  bool deactivate = false;

  /// A new admin (signed by the current admin) and the new admin's
  /// acceptance: its secret key here, or the signature in [acceptance].
  Uint8List? newAdmin;
  Uint8List? newAdminSecret;
  Uint8List? acceptance;

  final List<Uint8List> addMaintainers = [];
  final List<Uint8List> removeMaintainers = [];
  ZxWriteRule? rule;

  bool get changesPolicy =>
      activate ||
      deactivate ||
      newAdmin != null ||
      addMaintainers.isNotEmpty ||
      removeMaintainers.isNotEmpty ||
      rule != null;

  bool get isEmpty => signer == null && !changesPolicy;
}

/// The Seal of the last generation of an archive and where it is.
class ZxLastSeal {
  final ZxSeal seal;

  /// The end of that generation's Footer (the next data_start).
  final int footerEnd;
  const ZxLastSeal(this.seal, this.footerEnd);
}

/// A writer's plan for the Seal of a new generation.
class ZxSealPlan {
  final Uint8List archiveId;
  final int dataStart;
  final ZxPolicy policy;
  final Uint8List? prevRoot;
  final Uint8List? prefixHash;
  final Uint8List? accept;
  final Uint8List? signer;
  final ZxPieceHasher hasher;

  /// Notes for the caller (an unsigned generation of a sealed archive).
  final List<String> warnings;

  ZxSealPlan._(this.archiveId, this.dataStart, this.policy, this.prevRoot,
      this.prefixHash, this.accept, this.signer, this.hasher, this.warnings);

  /// The plan for a generation written at [dataStart] (the end of the
  /// last Footer, 0 for a new archive whose Header is [headerSize] bytes)
  /// after [last] (the last generation's Seal, null when it has none);
  /// null when the generation gets no Seal. [prefix] gives the SHA-256 of
  /// the bytes before [dataStart] (read only for an activation).
  static ZxSealPlan? make(
      {required Uint8List archiveId,
      required int dataStart,
      required int generation,
      int headerSize = 0,
      ZxLastSeal? last,
      ZxSealOptions? options,
      Uint8List Function()? prefix,
      bool multiVolume = false}) {
    final o = options ?? ZxSealOptions();
    final prev = last?.seal;
    final active = prev != null && prev.policy.active;
    if (!active && !o.activate) {
      if (o.changesPolicy || o.signer != null) {
        throw const SevenZipException(
            'zx: sealing is not active in this archive (activate it with '
            'zx sign)',
            SevenZipError.unsupported);
      }
      return null;
    }
    if (multiVolume) {
      throw const SevenZipException(
          'zx: signed generations are not supported in volume sets',
          SevenZipError.unsupported);
    }
    final signer = o.signer;
    final signerPk = signer == null ? null : publicKeyOf(signer);
    final warnings = <String>[];
    ZxPolicy policy;
    Uint8List? prevRoot;
    Uint8List? prefixHash;
    if (o.activate && !active) {
      if (signerPk == null) {
        throw const SevenZipException(
            'zx: activating seals needs the admin key (-msign)',
            SevenZipError.unsupported);
      }
      final admin = o.newAdmin ?? signerPk;
      if (!_eq(admin, signerPk)) {
        throw const SevenZipException(
            'zx: the key that activates seals becomes the admin',
            SevenZipError.unsupported);
      }
      policy = ZxPolicy(admin,
          maintainers: [...o.addMaintainers],
          rule: o.rule ?? ZxWriteRule.maintainers,
          seq: (prev?.policy.seq ?? -1) + 1);
      prefixHash = dataStart == 0 ? null : prefix!();
    } else {
      final p = prev!.policy;
      prevRoot = prev.root;
      if (last!.footerEnd != dataStart) {
        throw const SevenZipException(
            'zx: the last generation does not end where the new one starts',
            SevenZipError.unsupported);
      }
      if (o.changesPolicy) {
        if (signerPk == null || !_eq(signerPk, p.admin)) {
          throw const SevenZipException(
              'zx: only the admin may change the roles (-msign with the '
              'admin key)',
              SevenZipError.unsupported);
        }
        final ms = [
          for (final m in p.maintainers)
            if (!o.removeMaintainers.any((r) => _eq(r, m))) m
        ];
        for (final a in o.addMaintainers) {
          if (!ms.any((m) => _eq(m, a))) ms.add(a);
        }
        policy = p.copyWith(
            admin: o.newAdmin,
            maintainers: ms,
            rule: o.rule,
            seq: p.seq + 1,
            active: o.deactivate ? false : null);
      } else {
        policy = p;
        if (signerPk == null) {
          warnings.add('zx: this archive is sealed and the new generation is '
              'not signed (-msign): it stays pending until an allowed key '
              'signs a later one');
        } else if (!p.allows(signerPk)) {
          throw const SevenZipException(
              'zx: this key is neither the admin nor an allowed maintainer '
              'of the archive',
              SevenZipError.unsupported);
        }
      }
    }
    Uint8List? accept;
    final na = o.newAdmin;
    if (na != null && prevRoot != null && !_eq(na, prev!.policy.admin)) {
      final s = o.newAdminSecret;
      if (s != null) {
        if (!_eq(publicKeyOf(s), na)) {
          throw const SevenZipException(
              'zx: the new admin key does not match its secret',
              SevenZipError.unsupported);
        }
        accept = zxAcceptSignature(s, archiveId, generation);
      } else {
        accept = o.acceptance;
      }
      if (accept == null ||
          !schnorrVerify(
              na, zxAcceptMessage(archiveId, na, generation), accept)) {
        throw const SevenZipException(
            'zx: a new admin must accept the role (its key, or its '
            'acceptance signature for this generation)',
            SevenZipError.unsupported);
      }
    }
    return ZxSealPlan._(archiveId, dataStart, policy, prevRoot, prefixHash,
        accept, signer, ZxPieceHasher(rawPrefix: headerSize), warnings);
  }

  /// The Seal bytes of generation [generation], whose Index hashed to
  /// [indexHash].
  Uint8List build(int generation, Uint8List indexHash) => zxSealBuild(
      archiveId: archiveId,
      generation: generation,
      dataStart: dataStart,
      dataHash: hasher.finish(),
      indexHash: indexHash,
      prevRoot: prevRoot,
      prefixHash: prefixHash,
      policy: policy,
      accept: accept,
      signerSecret: signer);
}

/// A sink that feeds the bytes of a generation to its [ZxSealPlan]: the
/// data, then (after [beginIndex]) the Index.
class ZxSealSink implements ZxSink {
  final ZxSink inner;
  final ZxSealPlan plan;
  Sha256? _index;
  ZxSealSink(this.inner, this.plan);

  /// The next bytes are the Index.
  void beginIndex() => _index = Sha256();

  /// The SHA-256 of the Index written since [beginIndex].
  Uint8List indexHash() => _index!.digest();

  /// The core digest of [payload], written next.
  void hint(Uint8List payload, Uint8List coreDigest) =>
      plan.hasher.hint(payload, coreDigest);

  @override
  void write(Uint8List b) {
    final i = _index;
    if (i != null) {
      i.update(b);
    } else {
      plan.hasher.add(b);
    }
    inner.write(b);
  }

  /// Writes the Seal and returns its size.
  int writeSeal(int generation) {
    final s = plan.build(generation, indexHash());
    inner.write(s);
    return s.length;
  }

  @override
  int get volume => inner.volume;
  @override
  int get position => inner.position;
  @override
  bool get multi => inner.multi;
  @override
  int? get room => inner.room;
  @override
  int? get emptyRoom => inner.emptyRoom;
  @override
  void nextVolume() => inner.nextVolume();
  @override
  List<ZxVolumeInfo> volumeTable() => inner.volumeTable();
  @override
  List<String> close() => inner.close();
}

// ---------------------------------------------------------------------------
// Reading and checking

/// Reads [len] bytes at [off] of the archive file.
typedef ZxReadAt = Uint8List Function(int off, int len);

/// Reads the Seal of the generation whose Footer ends at [footerEnd]:
/// (Footer, Seal or null) or null when there is no valid Footer there.
(ZxFooter, ZxSeal?)? zxReadSealAt(
    ZxReadAt readAt, int footerEnd, Uint8List archiveId) {
  if (footerEnd < zxFooterSize) return null;
  final f =
      ZxFooter.tryParse(readAt(footerEnd - zxFooterSize, zxFooterSize), 0);
  if (f == null) return null;
  final sealStart = f.indexOffset + f.indexSize;
  if (sealStart + f.sealSize != footerEnd - zxFooterSize) return null;
  if (f.sealSize == 0) return (f, null);
  return (f, zxSealParse(readAt(sealStart, f.sealSize), archiveId));
}

/// Checks the seals of an archive from its last generation back to its
/// activation. [full] also hashes the data and the bytes before the
/// activation (one pass over the file); otherwise only the Index of each
/// generation is hashed and the signatures, chain and roles are checked.
/// [lastFooterEnd] is the end of the last valid Footer; [lastGeneration]
/// its number. Returns the generations from the oldest checked (the
/// activation, or the first plain one after the newest seal) to the last.
List<ZxGenerationSeal> zxCheckSeals(
    ZxReadAt readAt, Uint8List archiveId, int lastFooterEnd, int lastGeneration,
    {bool full = false, int chunk = 1 << 20, int? maxPlain}) {
  // walk back: the newest first, through the data_start of each Footer;
  // a run of plain generations is followed to the seal before it (at most
  // [maxPlain] of them, all of them in a full check)
  final limit = maxPlain ?? (full ? -1 : 256);
  final back = <ZxGenerationSeal>[];
  var end = lastFooterEnd;
  var gen = lastGeneration;
  var plain = 0;
  while (true) {
    (ZxFooter, ZxSeal?)? fs;
    String? err;
    try {
      fs = zxReadSealAt(readAt, end, archiveId);
    } on SevenZipException catch (e) {
      err = e.message;
    }
    if (fs == null) {
      back.add(ZxGenerationSeal(gen, end, null, ZxSealState.broken)
        ..problem = err ?? 'no valid Footer');
      break;
    }
    final (footer, seal) = fs;
    final g = ZxGenerationSeal(seal?.generation ?? gen, end, seal,
        seal == null ? ZxSealState.plain : ZxSealState.sealed);
    back.add(g);
    if (seal == null) {
      plain++;
      if (footer.dataStart <= 0 ||
          footer.dataStart >= end ||
          (limit >= 0 && plain >= limit)) {
        break;
      }
      end = footer.dataStart;
      gen--;
      continue;
    }
    if (footer.dataStart != seal.dataStart) {
      g.state = ZxSealState.broken;
      g.problem = 'the Footer and the seal disagree';
    }
    // the Index hash (cheap: the Index is small)
    final ih = _hashRange(readAt, footer.indexOffset, footer.indexSize, chunk);
    if (!_eq(ih, seal.indexHash)) {
      g.state = ZxSealState.broken;
      g.problem ??= 'the Index was changed';
    }
    if (full) {
      final dh = _dataHash(readAt, seal.dataStart, footer.indexOffset, chunk);
      if (dh == null || !_eq(dh, seal.dataHash)) {
        g.state = ZxSealState.broken;
        g.problem ??= 'the data was changed';
      }
      if (seal.isGenesis && seal.dataStart > 0) {
        final ph = _hashRange(readAt, 0, seal.dataStart, chunk);
        if (!_eq(ph, seal.prefixHash!)) {
          g.state = ZxSealState.broken;
          g.problem ??= 'the generations before the activation were changed';
        }
      }
    }
    if (seal.isGenesis || seal.dataStart == 0) break;
    end = seal.dataStart;
    gen = seal.generation - 1;
  }
  final gens = back.reversed.toList();
  // plain generations after a seal follow its number
  for (var i = 1; i < gens.length; i++) {
    if (gens[i].seal == null && gens[i - 1].generation >= 0) {
      gens[i].generation = gens[i - 1].generation + 1;
    }
  }
  // forward: chain, signatures and roles
  ZxGenerationSeal? prev;
  for (final g in gens) {
    final s = g.seal;
    final p = prev?.seal;
    if (s == null) {
      if (prev != null && p != null && p.policy.active) {
        g.state = ZxSealState.broken;
        g.problem ??= 'the seal is missing';
      } else if (g.state != ZxSealState.broken) {
        g.state = ZxSealState.plain;
      }
      prev = g;
      continue;
    }
    final problems = <String>[];
    if (s.isGenesis) {
      if (!s.isSigned) {
        problems.add('an activation must be signed');
      } else if (!_eq(s.signer!, s.policy.admin)) {
        problems.add('the activation is not signed by its admin');
      }
    } else {
      if (p == null) {
        problems.add('the previous seal is missing');
      } else {
        if (!_eq(s.prevRoot!, p.root)) problems.add('the chain is broken');
        if (s.generation != p.generation + 1) {
          problems.add('generation numbers do not follow');
        }
        final before = p.policy;
        if (!before.active) problems.add('sealing was switched off');
        final changed = !s.policy.sameAs(before) || s.policy.seq != before.seq;
        if (s.isSigned) {
          final pk = s.signer!;
          if (changed) {
            if (!_eq(pk, before.admin)) {
              problems.add('the roles were changed by a key that is not the '
                  'admin');
            }
            if (s.policy.seq <= before.seq) {
              problems.add('the policy sequence did not increase');
            }
            if (!_eq(s.policy.admin, before.admin)) {
              final a = s.accept;
              if (a == null ||
                  !schnorrVerify(
                      s.policy.admin,
                      zxAcceptMessage(archiveId, s.policy.admin, s.generation),
                      a)) {
                problems.add('the new admin did not accept the role');
              }
            }
          } else if (!before.allows(pk)) {
            problems.add('signed by a key that may not sign');
          }
          g.role = _eq(pk, before.admin)
              ? 'admin'
              : before.isMaintainer(pk)
                  ? 'maintainer'
                  : null;
        } else if (changed) {
          problems.add('the roles were changed without a signature');
        }
      }
    }
    if (s.isGenesis && s.isSigned) g.role = 'admin';
    if (s.isSigned && !s.signatureValid) problems.add('bad signature');
    if (problems.isNotEmpty) {
      g.state = ZxSealState.broken;
      g.problem ??= problems.join('; ');
    } else if (g.state != ZxSealState.broken) {
      g.state = s.isSigned ? ZxSealState.sealed : ZxSealState.pending;
    }
    prev = g;
  }
  // pending generations under a later valid seal are covered by it
  var sealedAfter = false;
  for (final g in gens.reversed) {
    if (g.state == ZxSealState.broken) {
      sealedAfter = false;
    } else if (g.state == ZxSealState.sealed) {
      sealedAfter = true;
    } else if (g.state == ZxSealState.pending && sealedAfter) {
      g.covered = true;
    }
  }
  return gens;
}

Uint8List _hashRange(ZxReadAt readAt, int off, int len, int chunk) {
  final h = Sha256();
  var p = off;
  final end = off + len;
  while (p < end) {
    final n = end - p < chunk ? end - p : chunk;
    h.update(readAt(p, n));
    p += n;
  }
  return h.digest();
}

Uint8List? _dataHash(ZxReadAt readAt, int start, int end, int chunk) {
  // the first generation starts with the archive Header
  var rawPrefix = 0;
  if (start == 0) {
    rawPrefix = zxHeaderSizeAt(readAt);
    if (rawPrefix <= 0) return null;
  }
  final h = ZxPieceHasher(rawPrefix: rawPrefix);
  var p = start;
  try {
    while (p < end) {
      final n = end - p < chunk ? end - p : chunk;
      h.add(readAt(p, n));
      p += n;
    }
    return h.finish();
  } on SevenZipException {
    return null;
  }
}

/// The size of the archive Header at the start of the file.
int zxHeaderSizeAt(ZxReadAt readAt) {
  try {
    final first = readAt(0, zxHeaderFixedSize);
    // the records_size field of the fixed part
    return zxHeaderFixedSize + getUint32LE(first, 56);
  } on SevenZipException {
    return -1;
  }
}

/// A [ZxReadAt] over a seekable stream.
ZxReadAt zxReadAtStream(SeekableInStream s) => (int off, int len) {
      final b = Uint8List(len);
      s.position = off;
      var got = 0;
      while (got < len) {
        final n = s.read(b, got, len - got);
        if (n <= 0) zxDamaged('unexpected end of the file');
        got += n;
      }
      return b;
    };

/// The end of the last valid Footer of a single-file archive of [length]
/// bytes whose Header is [headerSize] bytes (no Index is decoded, so this
/// works without the password of an encrypted archive), or -1.
int zxLastFooterEnd(ZxReadAt readAt, int length, int headerSize) {
  bool valid(int end) {
    if (end - zxFooterSize < headerSize) return false;
    final f = ZxFooter.tryParse(readAt(end - zxFooterSize, zxFooterSize), 0);
    return f != null &&
        f.position == end - zxFooterSize &&
        f.indexOffset >= headerSize &&
        f.dataStart < end;
  }

  if (valid(length)) return length;
  const chunk = 1 << 16;
  var hi = length;
  while (hi > headerSize) {
    final lo = hi - chunk < headerSize ? headerSize : hi - chunk;
    final n = hi - lo + 3 > length - lo ? length - lo : hi - lo + 3;
    final b = readAt(lo, n);
    for (var i = n - 4; i >= 0; i--) {
      if (getUint32LE(b, i) == zxFooterMagic) {
        final end = lo + i + 4;
        if (valid(end)) return end;
      }
    }
    hi = lo;
  }
  return -1;
}

/// The seals of the single-file archive at [path] (see [zxCheckSeals]),
/// read without the password: only the Header, the Footers, the Seals and
/// (with [full]) the stored bytes are read. Empty for a volume set.
List<ZxGenerationSeal> zxCheckSealsOfFile(String path, {bool full = false}) {
  final s = openInputFile(path);
  try {
    final header = ZxArchiveReader.readHeader(s);
    if (header == null) {
      throw const SevenZipException(
          'not a .zx archive', SevenZipError.isNotArc);
    }
    if (header.multiVolume) return const [];
    final readAt = zxReadAtStream(s);
    final end = zxLastFooterEnd(readAt, s.length, header.size);
    if (end < 0) {
      throw const SevenZipException('no valid Footer', SevenZipError.headers);
    }
    return zxCheckSeals(readAt, header.archiveId, end, -1, full: full);
  } finally {
    s.close();
  }
}
