// The seal types of a .zx archive (docs/zx-format.md "Seals") that the
// readers of the seals hold: the policy, a parsed Seal, the state of each
// generation and its summary. Plain Dart: the web client compiles them
// with dart2js. Building, parsing and checking Seals is in zx_seal.dart.

import 'dart:typed_data';

import '../../crypto/nip19.dart';
import '../../crypto/schnorr.dart';

/// Who may sign the generations of an archive.
enum ZxWriteRule {
  /// Only the admin.
  admin,

  /// The admin and the maintainers.
  maintainers,
}

/// The roles of a sealed archive, carried in every Seal.
class ZxPolicy {
  /// The x-only public key of the admin.
  final Uint8List admin;
  final List<Uint8List> maintainers;
  final ZxWriteRule rule;

  /// Raised by each change.
  final int seq;

  /// False when the admin switched sealing off with this generation.
  final bool active;

  ZxPolicy(this.admin,
      {List<Uint8List>? maintainers,
      this.rule = ZxWriteRule.maintainers,
      this.seq = 0,
      this.active = true})
      : maintainers = maintainers ?? const [];

  bool isMaintainer(List<int> pk) {
    for (final m in maintainers) {
      if (_eq(m, pk)) return true;
    }
    return false;
  }

  /// True when [pk] may sign a generation under this policy.
  bool allows(List<int> pk) =>
      _eq(admin, pk) || (rule == ZxWriteRule.maintainers && isMaintainer(pk));

  ZxPolicy copyWith(
          {Uint8List? admin,
          List<Uint8List>? maintainers,
          ZxWriteRule? rule,
          int? seq,
          bool? active}) =>
      ZxPolicy(admin ?? this.admin,
          maintainers: maintainers ?? this.maintainers,
          rule: rule ?? this.rule,
          seq: seq ?? this.seq,
          active: active ?? this.active);

  /// Same roles, rule and state (the sequence aside).
  bool sameAs(ZxPolicy o) {
    if (!_eq(admin, o.admin) ||
        rule != o.rule ||
        active != o.active ||
        maintainers.length != o.maintainers.length) {
      return false;
    }
    for (var i = 0; i < maintainers.length; i++) {
      if (!_eq(maintainers[i], o.maintainers[i])) return false;
    }
    return true;
  }
}

bool _eq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A parsed Seal.
class ZxSeal {
  final int generation;
  final int dataStart;
  final Uint8List dataHash;
  final Uint8List indexHash;

  /// The root of the previous generation's Seal; null for an activation.
  final Uint8List? prevRoot;

  /// For an activation: SHA-256 of the bytes before [dataStart].
  final Uint8List? prefixHash;
  final ZxPolicy policy;

  /// A new admin's signature accepting the role (see [zxAcceptMessage]).
  final Uint8List? accept;

  /// The signer and the signature; null for an unsigned (pending) Seal.
  final Uint8List? signer;
  final Uint8List? signature;

  /// root = SHA-256("zx/seal/1" || archive_id || body).
  final Uint8List root;

  ZxSeal(
      this.generation,
      this.dataStart,
      this.dataHash,
      this.indexHash,
      this.prevRoot,
      this.prefixHash,
      this.policy,
      this.accept,
      this.signer,
      this.signature,
      this.root);

  bool get isGenesis => prevRoot == null;
  bool get isSigned => signature != null;

  /// True when the signature verifies.
  bool get signatureValid =>
      signature != null && schnorrVerify(signer!, root, signature!);
}

/// The state of one generation's seal.
enum ZxSealState {
  /// No seal, sealing not active.
  plain,

  /// Signed by an allowed key, and its chain checks.
  sealed,

  /// Not signed (written without a key) while sealing is active; covered
  /// when a later generation is sealed.
  pending,

  /// A hash, signature, chain or role does not check, or the seal is
  /// missing while sealing is active.
  broken,
}

/// The seal of one generation, as checked.
class ZxGenerationSeal {
  /// Its number (-1 when not known: a plain generation read without its
  /// Index).
  int generation;

  /// The end of its Footer.
  final int footerEnd;
  final ZxSeal? seal;
  ZxSealState state;

  /// The role of the signer under the policy in force (admin, maintainer).
  String? role;

  /// What does not check.
  String? problem;

  /// A pending generation that a later sealed one covers.
  bool covered = false;

  /// The policy in force after this generation.
  ZxPolicy? get policy => seal?.policy;

  ZxGenerationSeal(this.generation, this.footerEnd, this.seal, this.state);
}

String _short(Uint8List pk) => npubEncode(pk);

/// One line about the seals of an archive (the last generation first),
/// or null when it has none.
String? zxSealSummary(List<ZxGenerationSeal> gens) {
  if (gens.isEmpty || gens.every((g) => g.state == ZxSealState.plain)) {
    return null;
  }
  final broken = [
    for (final g in gens)
      if (g.state == ZxSealState.broken) g
  ];
  if (broken.isNotEmpty) {
    final g = broken.last;
    return 'BROKEN at generation ${g.generation}: ${g.problem}';
  }
  final last = gens.last;
  final sealed = [
    for (final g in gens)
      if (g.state == ZxSealState.sealed) g
  ];
  final admin = last.policy?.admin ?? sealed.lastOrNull?.policy?.admin;
  final sb = StringBuffer();
  if (last.state == ZxSealState.plain) {
    sb.write('switched off');
    if (sealed.isNotEmpty) {
      sb.write(' after generation ${sealed.last.generation}');
    }
    return sb.toString();
  }
  if (last.state == ZxSealState.sealed) {
    sb.write('sealed by ${_short(last.seal!.signer!)} (${last.role ?? '?'})'
        ' at generation ${last.generation}');
  } else {
    final p =
        gens.reversed.takeWhile((g) => g.state == ZxSealState.pending).length;
    sb.write('$p pending generation${p == 1 ? '' : 's'} (not signed)');
    if (sealed.isNotEmpty) {
      sb.write(', last sealed generation ${sealed.last.generation}');
    }
  }
  if (admin != null) sb.write('; admin ${_short(admin)}');
  return sb.toString();
}
