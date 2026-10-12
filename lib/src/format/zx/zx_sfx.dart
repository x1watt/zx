// Self-extracting .zx archives (x.zx.sfx): a POSIX sh stub, small native
// engines (wasm3 with a few host functions, one per CPU), the decoder as
// WebAssembly (the C port of the zx reader and of zcm, native/sfx), then
// the .zx archive unchanged. `sh x.zx.sfx` extracts it on a Linux machine
// without zx; zx itself opens the archive after the stub
// (docs/architecture.md, section 16.1).
//
// Layout:
//   0             the stub (text, at most 4 KiB, padded with new lines)
//   4096 * k      each engine, at a multiple of 4096 so that dd can cut it
//                 out with 4 KiB blocks (an ELF file ignores the bytes
//                 after its end)
//   ...           the decoder (zxsfx.wasm)
//   ...           the archive, then nothing: its Footer ends the file
//
// The engines and the decoder come from native/sfx (tool/build_sfx.sh)
// and are compiled into zx (zx_sfx_payload.dart).

import 'dart:typed_data';

import '../../codec/zcm/zcm.dart' show zcmCodecId, zcmParseProps;
import '../../common/method_props.dart' show InvalidArgException;
import '../../io/streams.dart';
import 'zx_codecs.dart';
import 'zx_format.dart';
import 'zx_reader.dart';
import 'zx_sfx_payload.dart';

/// The first bytes of every .zx.sfx file.
const String zxSfxMarker = '#!/bin/sh\n# zx self-extracting archive';

/// The CPUs an engine exists for (uname -m families).
const List<String> zxSfxArches = ['x86_64', 'aarch64', 'riscv64', 'arm'];

/// The engines a .zx.sfx carries when none are named.
const List<String> zxSfxDefaultArches = ['x86_64', 'aarch64'];

/// The largest zcm model budget the decoder accepts (its memory is a
/// 32-bit WebAssembly memory, 4 GiB at most).
const int zxSfxMaxZcmMiB = 2048;

/// Whether [b] (its first [n] bytes) starts like a .zx.sfx file.
bool zxSfxHasMarker(Uint8List b, int n) {
  const m = zxSfxMarker;
  if (n < m.length) return false;
  for (var i = 0; i < m.length; i++) {
    if (b[i] != m.codeUnitAt(i)) return false;
  }
  return true;
}

/// Where the archive of a .zx.sfx file starts: found from its last Footer
/// (the archive ends the file), checked against the Header magic. Null
/// when [s] is not a .zx.sfx file.
int? zxSfxArchiveStart(SeekableInStream s) {
  final len = s.length;
  if (len < 4096 + 64 + zxFooterSize) return null;
  final head = Uint8List(zxSfxMarker.length);
  s.position = 0;
  if (readFully(s, head, 0, head.length) != head.length ||
      !zxSfxHasMarker(head, head.length)) {
    return null;
  }
  final ft = Uint8List(zxFooterSize);
  s.position = len - zxFooterSize;
  if (readFully(s, ft, 0, zxFooterSize) != zxFooterSize) return null;
  final f = ZxFooter.tryParse(ft, 0);
  if (f == null) return null;
  final base = len - zxFooterSize - f.position;
  if (base < 4096 || base > len - 64) return null;
  final magic = Uint8List(8);
  s.position = base;
  if (readFully(s, magic, 0, 8) != 8 || !ZxHeader.hasMagic(magic)) {
    return null;
  }
  return base;
}

/// Why the archive of [r] can not go into a .zx.sfx, or null when it can:
/// the decoder reads store, LZMA, LZMA2, the branch filters, Delta and
/// zcm (with a model budget of at most [zxSfxMaxZcmMiB]), the CRC-32C,
/// xxHash64 and SHA-256 block checks, the last generation of one file (no
/// volumes, no incremental Index), no database and no streamed archive.
/// [readAt] reads the bytes of the archive (for the block headers).
String? zxSfxCheck(ZxArchiveReader r, Uint8List Function(int, int) readAt) {
  final h = r.header;
  if (h.multiVolume) return 'a volume set can not be self-extracting';
  if (h.streamed) return 'a streamed archive can not be self-extracting';
  final idx = r.lastIndex;
  if (idx.database != null || idx.base != null) {
    return 'an archive with a database can not be self-extracting';
  }
  const allowed = {
    ZxCodecId.store,
    ZxCodecId.lzma,
    ZxCodecId.lzma2,
    ZxCodecId.bcj,
    ZxCodecId.arm,
    ZxCodecId.armt,
    ZxCodecId.arm64,
    ZxCodecId.ppc,
    ZxCodecId.sparc,
    ZxCodecId.ia64,
    ZxCodecId.riscv,
    ZxCodecId.delta,
    zcmCodecId,
  };
  final meta = h.metaChain;
  final chains = <ZxChain>[...idx.chains.values, if (meta != null) meta];
  for (final c in chains) {
    var compressors = 0;
    for (final k in c.coders) {
      if (!allowed.contains(k.codecId)) {
        return 'the self-extracting decoder does not read '
            '${zxChainName(c)} (it reads LZMA, LZMA2, zcm, the branch '
            'filters and Delta: choose one with -m0)';
      }
      final info = zxCodecById(k.codecId);
      if (info == null || !info.isFilter) compressors++;
      if (k.codecId == zcmCodecId) {
        int mib;
        try {
          mib = zcmParseProps(k.props).memoryMiB;
        } on SevenZipException {
          return 'damaged zcm props';
        }
        if (mib > zxSfxMaxZcmMiB) {
          return 'zcm with a model of more than $zxSfxMaxZcmMiB MiB can not '
              'be self-extracting (its decoder is limited to 4 GiB of '
              'memory): add -mmem=${zxSfxMaxZcmMiB ~/ 1024}g';
        }
      }
    }
    if (compressors > 1) {
      return 'the self-extracting decoder reads one compressor per chain';
    }
  }
  for (final b in idx.blocks) {
    if (b.unpackedSize > (1 << 30)) {
      return 'blocks of more than 1 GiB can not be self-extracting';
    }
    final hb = readAt(b.offset, b.headerSize);
    final bh = ZxBlockHeader.tryParse(hb, 0, hb.length);
    if (bh == null) return 'damaged block header';
    if (bh.checkType > ZxCheck.sha256) {
      return 'the self-extracting decoder checks blocks with CRC-32C, '
          'xxHash64 or SHA-256 only (-mcheck)';
    }
  }
  return null;
}

/// The bytes before the archive in a .zx.sfx with the engines of
/// [arches]: the stub, the engines and the decoder. The archive follows.
Uint8List zxSfxPrefix(List<String> arches) {
  final engines = <(String, Uint8List)>[];
  for (final a in arches) {
    final e = zxSfxEngine(a);
    if (e == null) {
      throw InvalidArgException(
          'zx: no self-extracting engine for $a (${zxSfxArches.join(', ')})');
    }
    engines.add((a, e));
  }
  final decoder = zxSfxDecoder();
  // offsets: the stub takes the first 4 KiB
  var pos = 4096;
  final places = <String>[];
  for (final (a, e) in engines) {
    places.add('$a:$pos:${e.length}');
    pos += (e.length + 4095) & ~4095;
  }
  final decoderOff = pos;
  final archiveOff = decoderOff + decoder.length;
  final stub = _stub(places.join(' '), decoderOff, decoder.length, archiveOff);
  if (stub.length > 4096) throw StateError('zx: the sfx stub is too long');
  final out = Uint8List(archiveOff);
  out.setRange(0, stub.length, stub);
  for (var i = stub.length; i < 4096; i++) {
    out[i] = 0x0A;
  }
  pos = 4096;
  for (final (_, e) in engines) {
    out.setRange(pos, pos + e.length, e);
    pos += (e.length + 4095) & ~4095;
  }
  out.setRange(decoderOff, archiveOff, decoder);
  return out;
}

// The stub: picks the engine of the CPU, cuts it out with dd into a
// folder where a program may run, and starts it on the decoder and the
// archive. POSIX sh, dd, uname and mkdir/mktemp only.
Uint8List _stub(String engines, int decoderOff, int decoderLen, int arcOff) {
  final s = '''$zxSfxMarker: run it with sh to extract its files.
#   sh NAME [-o DIR] [-y] [FILE...]   extract (to DIR; -y overwrites)
#   sh NAME -l                        list the files
#   sh NAME -t                        test the files
# zx reads it too (zx x NAME). The decoder runs in wasm3 (MIT License,
# Steven Massey, Volodymyr Shymanskyy and the wasm3 contributors).
ZXSFX_ENGINES="$engines"
ZXSFX_DECODER=$decoderOff:$decoderLen
ZXSFX_ARCHIVE=$arcOff
self=\$0
m=\$(uname -m 2>/dev/null)
case \$m in
  x86_64|amd64) a=x86_64 ;;
  aarch64|arm64|armv8*) a=aarch64 ;;
  riscv64) a=riscv64 ;;
  armv7*|armv6*|armhf|arm) a=arm ;;
  *) a=\$m ;;
esac
eo=; el=
for e in \$ZXSFX_ENGINES; do
  case \$e in "\$a":*) r=\${e#*:}; eo=\${r%%:*}; el=\${r#*:} ;; esac
done
if [ -z "\$eo" ]; then
  echo "zx sfx: no engine for this CPU (\$m) in this file: \$ZXSFX_ENGINES" >&2
  echo "zx sfx: zx extracts it too: zx x \$self" >&2
  exit 2
fi
d=
for t in "\${TMPDIR:-/tmp}" /tmp /var/tmp /dev/shm "\${HOME:-.}" .; do
  [ -d "\$t" ] && [ -w "\$t" ] || continue
  d=\$(mktemp -d "\$t/zxsfx.XXXXXXXX" 2>/dev/null) ||
    { d=\$t/zxsfx.\$\$; mkdir -m 700 "\$d" 2>/dev/null || { d=; continue; }; }
  if dd if="\$self" of="\$d/e" bs=4096 skip=\$((eo / 4096)) \\
      count=\$(((el + 4095) / 4096)) 2>/dev/null &&
      chmod 700 "\$d/e" && "\$d/e" -v >/dev/null 2>&1; then
    break
  fi
  rm -rf "\$d"
  d=
done
if [ -z "\$d" ]; then
  echo "zx sfx: no folder where a program may run (set TMPDIR)" >&2
  exit 2
fi
trap 'rm -rf "\$d"' EXIT
trap 'exit 130' HUP INT TERM
"\$d/e" "\$self" \${ZXSFX_DECODER%%:*} \${ZXSFX_DECODER#*:} "\$self" \$ZXSFX_ARCHIVE "\$@"
exit \$?
''';
  return Uint8List.fromList(s.codeUnits);
}
