// The Compression section of the add and new archive dialogs for .zx:
// Auto (zx chooses the zcm level, memory and threads for this machine and
// the input, within a time budget) or Manual (a method, and for zcm its
// memory, LSTM and threads). The estimate (ZxArchive.estimate) runs in a
// background isolate, debounced after each change; a result for older
// inputs is dropped.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

import '../settings.dart';

/// Estimates an update without compressing (ZxArchive.estimate; tests
/// pass a fake).
typedef Estimator = Future<ZxEstimate> Function(
  List<ZxSource> sources, {
  ZxOptions options,
});

/// The methods of Manual, as ZxPrefs.method stores them.
const kZxMethods = <String>[
  'zcm:1',
  'zcm:2',
  'zcm:3',
  'zcm:4',
  'zcm:5',
  'zcm:6',
  'zcm:7',
  'zcm:8',
  'zcm:9',
  'LZMA2',
  'PPMd8',
  'PPMd',
  'BZip2',
  'Deflate',
  'zpaq',
  'store',
];

const _zcmNames = {
  1: 'fastest',
  2: 'fast',
  4: 'normal',
  6: 'max',
  8: 'ultra',
  9: 'cmix',
};

/// The zcm level of [method] ('zcm:6'), or null for the other methods.
int? zcmLevelOf(String method) =>
    method.startsWith('zcm:') ? int.tryParse(method.substring(4)) : null;

String zxMethodLabel(String m) {
  final l = zcmLevelOf(m);
  if (l != null) {
    final n = _zcmNames[l];
    return n == null ? 'zcm level $l' : 'zcm level $l ($n)';
  }
  return switch (m) {
    'LZMA2' => 'LZMA2',
    'PPMd8' => 'PPMd8 (text)',
    'PPMd' => 'PPMd (text)',
    'store' => 'Store (no compression)',
    _ => m,
  };
}

/// Memory budgets of Manual zcm (MiB; 0: the level's default).
const kZcmMemoryMiB = <int>[
  0,
  64,
  128,
  256,
  512,
  1024,
  2048,
  3072,
  4096,
  6144,
  8192,
  12288,
  16384,
];

const kThreadChoices = <int>[0, 1, 2, 4, 6, 8, 12, 16];
const kLstmCells = <int>[32, 64, 128, 200];

String speedLabel(String s) => switch (s) {
  'fast' => 'Fast',
  'balanced' => 'Balanced',
  'max' => 'Max',
  _ => 'Custom',
};

/// "1.2 GiB", "340 MiB".
String memText(int bytes) {
  if (bytes >= 1 << 30) {
    final g = bytes / (1 << 30);
    return '${g >= 10 ? g.round() : g.toStringAsFixed(1)} GiB';
  }
  if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).round()} MiB';
  return '${(bytes / 1024).ceil()} KiB';
}

String memoryChoiceLabel(int mib, int? level) {
  if (mib == 0) {
    return level == null
        ? 'Level default'
        : 'Level default (${memText(zcmDefaultMemoryMiB(level) << 20)})';
  }
  return memText(mib << 20);
}

/// "~40 seconds", "~12 minutes", "~2.5 hours".
String approxTime(Duration d) {
  final s = d.inMilliseconds / 1000;
  if (s < 1) return 'under a second';
  if (s < 1.5) return '~1 second';
  if (s < 90) return '~${s.round()} seconds';
  final m = s / 60;
  if (m < 90) return '~${m.round()} minutes';
  final h = m / 60;
  if (h >= 48) return '~${(h / 24).round()} days';
  return '~${h >= 10 ? h.round() : h.toStringAsFixed(1)} hours';
}

/// The compression [p] asks for (without a pinned estimate).
ZxCompression zxCompressionOf(ZxPrefs p) {
  if (p.auto) {
    if (p.speed == 'custom') {
      return ZxCompression.auto(timeBudget: Duration(minutes: p.minutes));
    }
    return ZxCompression.auto(
      speed: ZxAutoSpeed.values.firstWhere(
        (e) => e.name == p.speed,
        orElse: () => ZxAutoSpeed.balanced,
      ),
    );
  }
  final threads = p.threads > 0 ? p.threads : null;
  final level = zcmLevelOf(p.method);
  if (level != null) {
    return ZxCompression.manual(
      zcm: ZcmOptions(
        level: level,
        memoryMiB: p.memoryMiB,
        lstm: p.lstm && level == 9,
        lstmCells: p.lstmCells,
        lstmLayers: p.lstmLayers,
      ),
      threads: threads,
    );
  }
  return ZxCompression.manual(chain: p.method, threads: threads);
}

/// The one line of an estimate: "Chosen: level 6, 1.2 GiB RAM, 2 threads,
/// ~3 minutes".
String chosenText(ZxEstimate e, {required bool auto}) {
  final what = e.zcmLevel != null
      ? 'level ${e.zcmLevel}${e.lstm ? ' + LSTM' : ''}'
      : e.method;
  return '${auto ? 'Chosen' : 'Estimate'}: $what, ${memText(e.memoryBytes)} '
      'RAM, ${e.threads} thread${e.threads == 1 ? '' : 's'}, '
      '${approxTime(e.time)}';
}

/// The .zx part of the compression settings of a dialog.
class ZxCompressionState {
  ZxPrefs prefs;

  /// The last estimate, and whether it is the one of the current inputs
  /// and settings.
  ZxEstimate? estimate;
  bool estimateCurrent = false;

  ZxCompressionState(this.prefs);

  /// What the update uses: the estimated zcm settings when Auto has a
  /// current estimate (what was shown is what runs), else the request.
  ZxCompression get compression {
    final e = estimate;
    if (prefs.auto && estimateCurrent && e != null && e.compression != null) {
      return e.compression!;
    }
    return zxCompressionOf(prefs);
  }
}

class ZxCompressionSection extends StatefulWidget {
  final ZxCompressionState state;

  /// The files and folders to add (the dialog changes the list in place).
  final List<String> sources;

  /// The level of the other methods (Manual), shared with the dialog.
  final int level;
  final ValueChanged<int> onLevel;
  final Estimator estimator;

  const ZxCompressionSection({
    super.key,
    required this.state,
    required this.sources,
    required this.level,
    required this.onLevel,
    required this.estimator,
  });

  @override
  State<ZxCompressionSection> createState() => _ZxCompressionSectionState();
}

class _ZxCompressionSectionState extends State<ZxCompressionSection> {
  Timer? _debounce;
  int _gen = 0;
  bool _running = false;
  String? _error;
  String _key = '';

  ZxCompressionState get _s => widget.state;
  ZxPrefs get _p => _s.prefs;

  String get _currentKey =>
      '${widget.sources.join('\n')}|${_p.toJson()}|${widget.level}';

  @override
  void initState() {
    super.initState();
    _schedule();
  }

  @override
  void didUpdateWidget(ZxCompressionSection old) {
    super.didUpdateWidget(old);
    if (_currentKey != _key) _schedule();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _set(ZxPrefs p) {
    setState(() => _s.prefs = p);
    _schedule();
  }

  void _schedule() {
    _key = _currentKey;
    _debounce?.cancel();
    _s.estimateCurrent = false;
    final gen = ++_gen;
    if (widget.sources.isEmpty) {
      _running = false;
      _s.estimate = null;
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      if (!mounted || gen != _gen) return;
      setState(() {
        _running = true;
        _error = null;
      });
      final lv = zcmLevelOf(_p.method) == null && !_p.auto
          ? widget.level
          : null;
      try {
        final e = await widget.estimator(
          [for (final s in widget.sources) ZxSource(s)],
          options: ZxOptions(
            level: lv,
            compression: zxCompressionOf(_p),
            dedup: _p.dedup,
          ),
        );
        if (!mounted || gen != _gen) return;
        setState(() {
          _s.estimate = e;
          _s.estimateCurrent = true;
          _running = false;
        });
      } catch (e) {
        if (!mounted || gen != _gen) return;
        setState(() {
          _running = false;
          _error = '$e';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final p = _p;
    final level = zcmLevelOf(p.method);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Compression', style: t.labelLarge),
            const Spacer(),
            SegmentedButton<bool>(
              key: const Key('zx-mode'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Auto'),
                  icon: Icon(Icons.auto_awesome_outlined),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Manual'),
                  icon: Icon(Icons.tune),
                ),
              ],
              selected: {p.auto},
              onSelectionChanged: (v) => _set(p.copyWith(auto: v.first)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (p.auto) ..._auto(p) else ..._manual(p, level),
        const SizedBox(height: 10),
        _estimateBox(context),
        const SizedBox(height: 4),
        CheckboxListTile(
          key: const Key('zx-dedup'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: p.dedup,
          onChanged: (v) => _set(p.copyWith(dedup: v ?? true)),
          title: const Text('Deduplicate identical data'),
        ),
      ],
    );
  }

  List<Widget> _auto(ZxPrefs p) => [
    Row(
      children: [
        const Text('Time budget'),
        const SizedBox(width: 12),
        Expanded(
          child: SegmentedButton<String>(
            key: const Key('zx-speed'),
            showSelectedIcon: false,
            segments: [
              for (final s in ZxPrefs.speeds)
                ButtonSegment(value: s, label: Text(speedLabel(s))),
            ],
            selected: {p.speed},
            onSelectionChanged: (v) => _set(p.copyWith(speed: v.first)),
          ),
        ),
      ],
    ),
    if (p.speed == 'custom')
      Row(
        children: [
          Expanded(
            child: Slider(
              key: const Key('zx-minutes'),
              min: 1,
              max: 240,
              divisions: 239,
              value: p.minutes.clamp(1, 240).toDouble(),
              label: '${p.minutes} min',
              onChanged: (v) =>
                  setState(() => _s.prefs = p.copyWith(minutes: v.round())),
              onChangeEnd: (v) => _set(_p.copyWith(minutes: v.round())),
            ),
          ),
          SizedBox(width: 90, child: Text('up to ${_s.prefs.minutes} min')),
        ],
      )
    else
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          switch (p.speed) {
            'fast' => 'Quick, lighter compression.',
            'max' => 'The strongest levels: slow, for archives kept long.',
            _ => 'A good ratio at a moderate speed.',
          },
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ),
  ];

  List<Widget> _manual(ZxPrefs p, int? level) {
    final safe = _s.estimate?.safeMemory;
    return [
      Wrap(
        spacing: 20,
        runSpacing: 8,
        children: [
          _labeled(
            'Method',
            DropdownButton<String>(
              key: const Key('zx-method'),
              value: kZxMethods.contains(p.method) ? p.method : 'zcm:4',
              onChanged: (v) => _set(p.copyWith(method: v)),
              items: [
                for (final m in kZxMethods)
                  DropdownMenuItem(value: m, child: Text(zxMethodLabel(m))),
              ],
            ),
          ),
          if (level == null && p.method != 'store')
            _labeled(
              'Level',
              DropdownButton<int>(
                key: const Key('zx-level'),
                value: const [1, 3, 5, 7, 9].contains(widget.level)
                    ? widget.level
                    : 5,
                onChanged: (v) {
                  widget.onLevel(v ?? 5);
                  _schedule();
                },
                items: [
                  for (final l in const [1, 3, 5, 7, 9])
                    DropdownMenuItem(value: l, child: Text('Level $l')),
                ],
              ),
            ),
          if (level != null)
            _labeled(
              'Memory per stream',
              DropdownButton<int>(
                key: const Key('zx-memory'),
                value: kZcmMemoryMiB.contains(p.memoryMiB) ? p.memoryMiB : 0,
                onChanged: (v) => _set(p.copyWith(memoryMiB: v ?? 0)),
                items: [
                  for (final m in kZcmMemoryMiB)
                    DropdownMenuItem(
                      value: m,
                      child: Text(memoryChoiceLabel(m, level)),
                    ),
                ],
              ),
            ),
          _labeled(
            'Threads',
            DropdownButton<int>(
              key: const Key('zx-threads'),
              value: kThreadChoices.contains(p.threads) ? p.threads : 0,
              onChanged: (v) => _set(p.copyWith(threads: v ?? 0)),
              items: [
                for (final n in kThreadChoices)
                  DropdownMenuItem(
                    value: n,
                    child: Text(n == 0 ? 'Automatic' : '$n'),
                  ),
              ],
            ),
          ),
        ],
      ),
      if (level != null) ...[
        const SizedBox(height: 4),
        Row(
          children: [
            Checkbox(
              key: const Key('zx-lstm'),
              value: p.lstm && level == 9,
              onChanged: level == 9
                  ? (v) => _set(p.copyWith(lstm: v ?? false))
                  : null,
            ),
            Flexible(
              child: Text(
                level == 9
                    ? 'LSTM (a little smaller, much slower)'
                    : 'LSTM (level 9 only)',
              ),
            ),
            if (level == 9 && p.lstm) ...[
              const SizedBox(width: 12),
              DropdownButton<int>(
                key: const Key('zx-lstm-cells'),
                value: kLstmCells.contains(p.lstmCells) ? p.lstmCells : 64,
                onChanged: (v) => _set(p.copyWith(lstmCells: v ?? 64)),
                items: [
                  for (final c in kLstmCells)
                    DropdownMenuItem(value: c, child: Text('$c cells')),
                ],
              ),
              const SizedBox(width: 12),
              DropdownButton<int>(
                key: const Key('zx-lstm-layers'),
                value: p.lstmLayers.clamp(1, 3),
                onChanged: (v) => _set(p.copyWith(lstmLayers: v ?? 1)),
                items: [
                  for (final l in const [1, 2, 3])
                    DropdownMenuItem(
                      value: l,
                      child: Text('$l layer${l == 1 ? '' : 's'}'),
                    ),
                ],
              ),
            ],
          ],
        ),
        if (safe != null)
          Text(
            'Safe maximum on this machine: ${memText(safe)} '
            '(${memText(_s.estimate!.availableMemory)} available, '
            '${_s.estimate!.cores} processors)',
            key: const Key('zx-safe'),
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
      ],
    ];
  }

  Widget _estimateBox(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final e = _s.estimate;
    final muted = TextStyle(color: cs.onSurfaceVariant, fontSize: 12);
    Widget body;
    if (widget.sources.isEmpty) {
      body = Text('Add files to see the estimate.', style: muted);
    } else if (_error != null) {
      body = Text(
        'No estimate: $_error',
        style: TextStyle(color: cs.error, fontSize: 12),
      );
    } else if (e == null) {
      body = Text('Estimating...', style: muted);
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            chosenText(e, auto: _p.auto),
            key: const Key('zx-chosen'),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            '${e.files} file${e.files == 1 ? '' : 's'}, '
            '${memText(e.inputSize)}; output about '
            '${memText(e.sizeLow)} to ${memText(e.sizeHigh)}',
            style: muted,
          ),
          for (final w in e.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: cs.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _sentence(w),
                      key: const Key('zx-warning'),
                      style: TextStyle(color: cs.error, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }
    return Container(
      key: const Key('zx-estimate'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 10),
            child: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.insights_outlined, size: 18, color: cs.primary),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }

  static String _sentence(String w) {
    if (w.isEmpty) return w;
    final s = w[0].toUpperCase() + w.substring(1);
    return s.endsWith('.') ? s : '$s.';
  }

  Widget _labeled(String label, Widget child) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      child,
    ],
  );
}
