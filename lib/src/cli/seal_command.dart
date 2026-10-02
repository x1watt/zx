// The `zx seal` command (zx extension, docs/zx-format.md "Seals"): shows
// and checks the signed generations of a .zx archive, signs it, and
// changes its roles.
//
//   zx seal [options] ARCHIVE

import '../host/io.dart';
import 'dart:typed_data';

import '../common/method_props.dart';
import '../crypto/nip19.dart';
import '../crypto/schnorr.dart';
import '../format/zx/zx_format.dart';
import '../format/zx/zx_handler.dart';
import '../format/zx/zx_reader.dart';
import '../format/zx/zx_seal.dart';
import '../io/streams.dart';
import 'globals.dart';
import 'std_stream.dart';

const String zxSealUsage = '''
Usage: zx seal [OPTIONS] ARCHIVE
Shows the seals of a .zx archive (its signed generations) and checks the
Index hashes, the signatures, the chain and the roles. Neither this nor
-full needs the password of an encrypted archive.
OPTIONS:
   -full              also check every stored byte (one pass over the file)
   -sign[=KEY]        append a generation signed with KEY: it signs the
                      history so far, or makes the changes below
   -activate          start sealing: KEY becomes the admin
   -off               switch sealing off (the admin)
   -add=NPUB[,NPUB]   add maintainers (the admin)
   -remove=NPUB[,..]  remove maintainers (the admin)
   -rule=RULE         who may sign: admin, or maintainers (and the admin)
   -admin=NPUB        hand the admin role to NPUB (the admin), who accepts
                      it with -adminkey=KEY (its key) or -accept=HEX
   -acceptance=KEY    print the acceptance signature of the new admin KEY
                      for the next generation (the new admin runs this)
   -p{Password}       password of an encrypted archive (to sign it)
KEY is an nsec, 64 hex digits, @FILE (its first line), or empty for the
environment variable ZX_NSEC. NPUB is an npub or 64 hex digits.
Exit code 1 when a seal does not check.
''';

/// Runs `zx seal` with [args] (after the word "seal"); returns the exit
/// code.
int runSealCommand(List<String> args, CliIo io) {
  void out(String s) => gStdOut.write(s);
  void err(String s) {
    gStdOut.flush();
    gStdErr.write(s);
  }

  var full = false;
  String? password;
  String? acceptanceKey;
  final props = <MapEntry<String, PropVariant>>[];
  var change = false;
  String? archive;
  for (final a in args) {
    if (a.startsWith('-') && a.length > 1) {
      final body = a.startsWith('--') ? a.substring(2) : a.substring(1);
      final eq = body.indexOf('=');
      final o = (eq < 0 ? body : body.substring(0, eq)).toLowerCase();
      var v = eq < 0 ? '' : body.substring(eq + 1);
      // @FILE relative to the working directory
      final wd = io.workingDirectory;
      if (v.startsWith('@') && wd != null && !File(v.substring(1)).isAbsolute) {
        v = '@$wd/${v.substring(1)}';
      }
      void prop(String name) {
        props.add(MapEntry(name, PropVariant.bstr(v)));
        change = true;
      }

      switch (o) {
        case 'full':
          full = true;
        case 'sign':
          props.add(MapEntry('sign', PropVariant.bstr(v)));
          change = true;
        case 'activate':
          props.add(MapEntry('seal', PropVariant.bstr('on')));
          change = true;
        case 'off':
          props.add(MapEntry('seal', PropVariant.bstr('off')));
          change = true;
        case 'add':
          prop('addmaintainer');
        case 'remove':
          prop('delmaintainer');
        case 'rule':
          prop('writerule');
        case 'admin':
          prop('admin');
        case 'adminkey':
          prop('adminkey');
        case 'accept':
          prop('adminaccept');
        case 'acceptance':
          acceptanceKey = v;
        case 'help' || 'h':
          out(zxSealUsage);
          return 0;
        default:
          if (a.startsWith('-p')) {
            password = a.substring(2);
            continue;
          }
          err('zx seal: Error: unknown option: $a\n$zxSealUsage');
          return 2;
      }
      continue;
    }
    if (archive != null) {
      err(zxSealUsage);
      return 2;
    }
    archive = a;
  }
  if (archive == null) {
    err(zxSealUsage);
    return 2;
  }
  final cwd = io.workingDirectory;
  var path = archive;
  if (cwd != null && !File(path).isAbsolute) path = '$cwd/$path';
  if (!File(path).existsSync()) {
    err('zx seal: Error: $archive: no such file\n');
    return 2;
  }
  try {
    if (acceptanceKey != null) {
      return _acceptance(path, acceptanceKey, out);
    }
    if (change) {
      final h = ZxHandler();
      h.setProperties(props);
      final raf = File(path).openSync();
      int gen;
      try {
        if (!h.open(FileInStream(raf), path: path, password: () => password)) {
          err('zx seal: Error: $archive is not a .zx archive\n');
          return 2;
        }
        gen = h.sealFile(path, password: password).generation;
        for (final w in h.options.write.warnings) {
          err('$w\n');
        }
      } finally {
        raf.closeSync();
      }
      out('$archive: generation $gen written\n');
    }
    return _status(path, archive, full, out);
  } on SevenZipException catch (e) {
    err('zx seal: Error: $archive: ${e.message}\n');
    return 2;
  } finally {
    gStdOut.flush();
  }
}

// the seals, read without the password (Footers and Seals only)
(List<ZxGenerationSeal>, ZxHeader) _check(String path, bool full) {
  final raf = File(path).openSync();
  try {
    final s = FileInStream(raf);
    final header = ZxArchiveReader.readHeader(s);
    if (header == null) {
      throw const SevenZipException(
          'not a .zx archive', SevenZipError.isNotArc);
    }
    if (header.multiVolume) {
      throw const SevenZipException(
          'a volume set has no seals', SevenZipError.unsupported);
    }
    final readAt = zxReadAtStream(s);
    final end = zxLastFooterEnd(readAt, s.length, header.size);
    if (end < 0) {
      throw const SevenZipException('no valid Footer', SevenZipError.headers);
    }
    return (
      zxCheckSeals(readAt, header.archiveId, end, -1, full: full),
      header
    );
  } finally {
    raf.closeSync();
  }
}

int _status(String path, String name, bool full, void Function(String) out) {
  final (gens, _) = _check(path, full);
  final summary = zxSealSummary(gens);
  if (summary == null) {
    out('$name: not sealed\n');
    return 0;
  }
  out('$name: $summary${full ? ' (every byte checked)' : ''}\n');
  out('  Gen  State    Signer                                                            Role\n');
  for (final g in gens) {
    final s = g.seal;
    final gen = g.generation < 0 ? '?' : '${g.generation}';
    final state = switch (g.state) {
      ZxSealState.sealed => 'sealed',
      ZxSealState.pending => g.covered ? 'covered' : 'pending',
      ZxSealState.broken => 'BROKEN',
      ZxSealState.plain => 'plain',
    };
    final signer = s?.signer == null ? '' : npubEncode(s!.signer!);
    final notes = [
      if (g.role != null) g.role!,
      if (s != null && s.isGenesis) 'activation',
      if (s != null && !s.policy.active) 'switched off',
      if (g.problem != null) g.problem!,
    ].join(', ');
    out('${gen.padLeft(5)}  ${state.padRight(8)} ${signer.padRight(65)} $notes\n');
  }
  final p = [
    for (final g in gens)
      if (g.seal != null) g.seal!.policy
  ].lastOrNull;
  if (p != null) {
    out('Admin: ${npubEncode(p.admin)}\n');
    out('Maintainers (${p.rule == ZxWriteRule.admin ? 'may not sign' : 'may sign'}):'
        '${p.maintainers.isEmpty ? ' none' : ''}\n');
    for (final m in p.maintainers) {
      out('  ${npubEncode(m)}\n');
    }
  }
  return gens.any((g) => g.state == ZxSealState.broken) ? 1 : 0;
}

// the acceptance signature of a new admin for the next generation
int _acceptance(String path, String key, void Function(String) out) {
  final secret = zxSecretKeyArg(key, what: 'new admin key');
  final (gens, header) = _check(path, false);
  final last = gens.isEmpty ? null : gens.last;
  if (last == null || last.generation < 0 || last.seal == null) {
    throw const SevenZipException(
        'the archive is not sealed', SevenZipError.unsupported);
  }
  final next = last.generation + 1;
  final sig = zxAcceptSignature(secret, header.archiveId, next);
  out('npub: ${npubEncode(publicKeyOf(secret))}\n'
      'generation: $next\n'
      'acceptance: ${zxHex(Uint8List.fromList(sig))}\n'
      'The admin hands over the role with:\n'
      '  zx seal -sign=KEY -admin=${npubEncode(publicKeyOf(secret))} '
      '-accept=${zxHex(Uint8List.fromList(sig))} ARCHIVE\n');
  return 0;
}
