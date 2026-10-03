// How a new .zx archive's generation is compressed, for the web "New
// archive" dialog: a wire-safe stand-in for ZxCompression
// (lib/src/zx_estimate.dart), which the web UI can not import (it pulls in
// package:zx/zx.dart, forbidden from the web build's import graph,
// test/web_safety_test.dart). Pure Dart (no dart:js_interop), so the
// dialog is a plain, VM-testable widget; the engine decodes the wire form
// with zx_web_create.dart's compressionFromWire.

/// How a new .zx archive's generation is compressed: a wire-safe stand-in
/// for ZxCompression, which this UI can not import.
class ZxWebCompression {
  final bool auto;

  /// auto: 'fast', 'balanced' or 'max'.
  final String speed;
  final int? timeBudgetSeconds;

  /// manual, a coder chain (`store`, `LZMA2`...).
  final String? chain;

  /// manual, zcm: the level (1 to 9); memory 0 is the level's default.
  final int? zcmLevel;
  final int zcmMemoryMiB;
  final bool lstm;

  const ZxWebCompression.auto({this.speed = 'balanced', this.timeBudgetSeconds})
      : auto = true,
        chain = null,
        zcmLevel = null,
        zcmMemoryMiB = 0,
        lstm = false;

  const ZxWebCompression.chain(this.chain)
      : auto = false,
        speed = 'balanced',
        timeBudgetSeconds = null,
        zcmLevel = null,
        zcmMemoryMiB = 0,
        lstm = false;

  const ZxWebCompression.zcm(this.zcmLevel,
      {this.zcmMemoryMiB = 0, this.lstm = false})
      : auto = false,
        speed = 'balanced',
        timeBudgetSeconds = null,
        chain = null;

  Map<String, Object?> toWire() => {
        'auto': auto,
        if (auto) 'speed': speed,
        if (auto && timeBudgetSeconds != null)
          'timeBudgetSeconds': timeBudgetSeconds,
        if (!auto && chain != null) 'chain': chain,
        if (!auto && zcmLevel != null) 'zcmLevel': zcmLevel,
        if (!auto && zcmLevel != null) 'zcmMemoryMiB': zcmMemoryMiB,
        if (!auto && zcmLevel != null) 'lstm': lstm,
      };
}
