// Creating a new .zx archive for the web version (docs/app.md "The web
// version"): a brand new generation written straight to an OutStream (the
// OPFS sink of library.dart), fed from browser File/Blob sources instead of
// disk paths. Pure Dart (no dart:js_interop), so it is unit-testable on the
// VM; the engine (lib/src/web/engine.dart) supplies the JS-backed sources.
//
// Reuses ZxArc (lib/src/cli/arc_zx.dart), the same adapter the CLI and the
// desktop app drive: setProperties resolves zcm:auto the same way, and
// updateItems(OutStream, ...) is already dart:io free (zx_handler.dart's
// updateItems only needs an OutStream, and forces a non-seekable sink's
// generation to be "streamed", which also turns dedup off automatically).

import '../cli/arc_zx.dart';
import '../cli/zx_zcm_auto.dart' show ZxAutoSpeed;
import '../codec/zcm/zcm.dart' show ZcmOptions;
import '../common/method_props.dart' show convertCliProperty;
import '../format/archive_types.dart';
import '../io/streams.dart';
import '../zx_estimate.dart' show ZxCompression;

/// One source file of a new web-created archive: an already-resolved
/// archive path, its size, an optional modification time (FILETIME ticks,
/// see cli/common.dart's dateTimeToFileTime), and a factory opening its
/// bytes (called once, when the writer is ready for it).
class ZxWebSource {
  final String path;
  final int size;
  final int? mTime;
  final InStream Function() open;
  ZxWebSource(this.path, this.size, this.mTime, this.open);
}

/// Archive item names from picked files' own names: flattened (no '/'),
/// never empty, de-duplicated with " (2)", " (3)"...
List<String> sanitizeArchiveItemNames(List<String> rawNames) {
  final used = <String>{};
  final out = <String>[];
  for (final raw in rawNames) {
    var n = raw.replaceAll(RegExp(r'[/\\\x00]'), '_').trim();
    if (n.isEmpty || n == '.' || n == '..') n = 'file';
    var candidate = n;
    if (used.contains(candidate)) {
      final dot = n.lastIndexOf('.');
      final stem = dot > 0 ? n.substring(0, dot) : n;
      final ext = dot > 0 ? n.substring(dot) : '';
      var i = 2;
      candidate = '$stem ($i)$ext';
      while (used.contains(candidate)) {
        i++;
        candidate = '$stem ($i)$ext';
      }
    }
    used.add(candidate);
    out.add(candidate);
  }
  return out;
}

/// The web dialog's plain-JSON compression choice as a [ZxCompression]
/// (the same type ZxCompressionSection builds on desktop): `{'auto': true,
/// 'speed': 'fast'|'balanced'|'max', 'timeBudgetSeconds': int?}`, or
/// `{'auto': false, 'chain': String}`, or `{'auto': false, 'zcmLevel': int,
/// 'zcmMemoryMiB': int, 'lstm': bool}`.
ZxCompression compressionFromWire(Map<String, Object?> m) {
  if (m['auto'] == true) {
    final speedName = m['speed'] as String? ?? 'balanced';
    final speed = ZxAutoSpeed.values.firstWhere((e) => e.name == speedName,
        orElse: () => ZxAutoSpeed.balanced);
    final tb = (m['timeBudgetSeconds'] as num?)?.toInt();
    return ZxCompression.auto(
        speed: speed, timeBudget: tb == null ? null : Duration(seconds: tb));
  }
  final chain = m['chain'] as String?;
  if (chain != null && chain.isNotEmpty) {
    return ZxCompression.manual(chain: chain);
  }
  final level = (m['zcmLevel'] as num?)?.toInt() ?? 4;
  final memMiB = (m['zcmMemoryMiB'] as num?)?.toInt() ?? 0;
  return ZxCompression.manual(
      zcm: ZcmOptions(
          level: level,
          memoryMiB: memMiB,
          lstm: m['lstm'] == true && level == 9));
}

class _WebCreateCallback extends ArchiveUpdateCallback
    implements CryptoGetTextPassword2 {
  final List<ZxWebSource> items;
  final String? password;
  final void Function(int done, int total, String? file)? onProgress;
  final int total;
  String? _current;

  _WebCreateCallback(this.items, this.password, this.onProgress)
      : total = items.fold(0, (a, b) => a + b.size);

  @override
  String? cryptoGetTextPassword2() => password;

  @override
  void setTotal(int total) {}

  @override
  void setCompleted(int completeValue) =>
      onProgress?.call(completeValue, total, _current);

  @override
  UpdateItemInfo getUpdateItemInfo(int index) =>
      const UpdateItemInfo(true, true, -1);

  @override
  Object? getProperty(int index, int propId) {
    final it = items[index];
    return switch (propId) {
      Kpid.path => it.path,
      Kpid.isDir => false,
      Kpid.isAnti => false,
      Kpid.size => it.size,
      Kpid.mTime => it.mTime,
      _ => null,
    };
  }

  @override
  InStream? getStream(int index) {
    _current = items[index].path;
    return items[index].open();
  }
}

/// Writes a new .zx archive of [items] to [out] (a non-seekable sink, e.g.
/// the OPFS OutStream of library.dart, forces the generation to be
/// "streamed" and dedup off, so nothing in the write path touches a real
/// filesystem). Returns the warnings collected (memory/time notices), for
/// the UI to show as a non-fatal notice.
List<String> buildZxArchive(
  OutStream out,
  List<ZxWebSource> items, {
  required ZxCompression compression,
  required bool solid,
  String? password,
  void Function(int done, int total, String? file)? onProgress,
}) {
  final arc = ZxArc();
  final switches = <String, String>{
    ...compression.toSwitches(),
    's': solid ? 'on' : 'off',
    'dedup': 'off',
  };
  arc.setProperties([
    for (final e in switches.entries) convertCliProperty(e.key, e.value),
  ]);
  arc.h.options.write.threads = 1;
  final cb = _WebCreateCallback(items, password, onProgress);
  arc.updateItems(out, items.length, cb);
  return arc.h.options.write.warnings;
}
