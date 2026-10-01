// The seals of a .zx archive (signed generations, docs/zx-format.md
// "Seals"): a badge in the status bar, a mark per version and the admin of
// the archive. They are checked with ZxArchive.seals (a background
// isolate, no password needed) and kept per archive handle.

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

/// The seals of each archive handle shown (an archive opened again after
/// a change is a new handle, so it is checked again).
class SealCache {
  static final Expando<Future<List<ZxGenerationSeal>>> _pending = Expando();
  static final Expando<List<ZxGenerationSeal>> _done = Expando();

  /// The seals of [a], checked once (empty for other formats).
  static Future<List<ZxGenerationSeal>> of(ZxArchive a) {
    if (a.format != 'zx') return Future.value(const []);
    return _pending[a] ??= a.seals().then((s) {
      _done[a] = s;
      return s;
    }, onError: (Object _) => const <ZxGenerationSeal>[]);
  }

  /// The seals of [a] when they were checked already.
  static List<ZxGenerationSeal>? known(ZxArchive a) => _done[a];

  /// The seal of generation [number], when known.
  static ZxGenerationSeal? generation(ZxArchive a, int number) {
    for (final g in known(a) ?? const <ZxGenerationSeal>[]) {
      if (g.generation == number) return g;
    }
    return null;
  }

  /// The admin of [a] (the last seal's policy), when it is sealed.
  static String? admin(ZxArchive a) {
    final s = known(a);
    if (s == null) return null;
    for (final g in s.reversed) {
      final p = g.policy;
      if (p != null) return npubEncode(p.admin);
    }
    return null;
  }
}

/// A short form of an npub: its start and end.
String shortNpub(String npub) => npub.length <= 20
    ? npub
    : '${npub.substring(0, 12)}...${npub.substring(npub.length - 6)}';

/// The words of a seal state for the UI.
String sealStateText(ZxGenerationSeal g) => switch (g.state) {
  ZxSealState.sealed => 'sealed',
  ZxSealState.pending => g.covered ? 'covered by a later seal' : 'not signed',
  ZxSealState.broken => 'BROKEN',
  ZxSealState.plain => 'not sealed',
};

/// The status bar badge: nothing for an archive that was never sealed.
class SealBadge extends StatefulWidget {
  final ZxArchive archive;
  const SealBadge({super.key, required this.archive});

  @override
  State<SealBadge> createState() => _SealBadgeState();
}

class _SealBadgeState extends State<SealBadge> {
  List<ZxGenerationSeal>? _seals;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SealBadge old) {
    super.didUpdateWidget(old);
    if (!identical(old.archive, widget.archive)) _load();
  }

  Future<void> _load() async {
    final a = widget.archive;
    setState(() => _seals = SealCache.known(a));
    final s = await SealCache.of(a);
    if (mounted && identical(a, widget.archive)) setState(() => _seals = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = _seals;
    final summary = s == null ? null : zxSealSummary(s);
    if (s == null || summary == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    final broken = s.any((g) => g.state == ZxSealState.broken);
    final last = s.last.state;
    final (icon, color, label) = broken
        ? (Icons.gpp_bad_outlined, cs.error, 'Seal broken')
        : last == ZxSealState.sealed
        ? (Icons.verified_outlined, cs.primary, 'Sealed')
        : last == ZxSealState.pending
        ? (Icons.pending_outlined, cs.tertiary, 'Not signed')
        : (Icons.remove_moderator_outlined, cs.onSurfaceVariant, 'Unsealed');
    return Tooltip(
      message: summary,
      child: InkWell(
        key: const Key('seal-badge'),
        onTap: () => showSealDialog(context, widget.archive, s),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The seal of every generation since the activation, with a full check.
Future<void> showSealDialog(
  BuildContext context,
  ZxArchive archive,
  List<ZxGenerationSeal> seals,
) => showDialog<void>(
  context: context,
  builder: (_) => _SealDialog(archive: archive, seals: seals),
);

class _SealDialog extends StatefulWidget {
  final ZxArchive archive;
  final List<ZxGenerationSeal> seals;
  const _SealDialog({required this.archive, required this.seals});

  @override
  State<_SealDialog> createState() => _SealDialogState();
}

class _SealDialogState extends State<_SealDialog> {
  late List<ZxGenerationSeal> _seals = widget.seals;
  bool _checking = false;
  bool _full = false;

  Future<void> _fullCheck() async {
    setState(() => _checking = true);
    try {
      final s = await widget.archive.seals(full: true);
      if (mounted) {
        setState(() {
          _seals = s;
          _full = true;
        });
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mono = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      color: cs.onSurfaceVariant,
    );
    ZxPolicy? policy;
    for (final g in _seals.reversed) {
      if (g.policy != null) {
        policy = g.policy;
        break;
      }
    }
    return AlertDialog(
      icon: const Icon(Icons.verified_outlined),
      title: const Text('Seals'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 460),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                zxSealSummary(_seals) ?? 'Not sealed',
                key: const Key('seal-summary'),
              ),
              const SizedBox(height: 4),
              Text(
                _full
                    ? 'Every stored byte was checked.'
                    : 'The Indexes, signatures, chain and roles were '
                          'checked; a full check also reads every byte.',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              const Divider(height: 20),
              for (final g in _seals)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 52,
                        child: Text(
                          g.generation < 0 ? '?' : 'v${g.generation}',
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              [
                                sealStateText(g),
                                if (g.role != null) 'by the ${g.role}',
                                if (g.seal?.isGenesis ?? false) 'activation',
                              ].join(', '),
                              style: TextStyle(
                                color: g.state == ZxSealState.broken
                                    ? cs.error
                                    : null,
                              ),
                            ),
                            if (g.seal?.signer != null)
                              SelectableText(
                                npubEncode(g.seal!.signer!),
                                style: mono,
                              ),
                            if (g.problem != null)
                              Text(
                                g.problem!,
                                style: TextStyle(color: cs.error),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (policy != null) ...[
                const Divider(height: 20),
                const Text('Admin'),
                SelectableText(npubEncode(policy.admin), style: mono),
                const SizedBox(height: 8),
                Text(
                  policy.rule == ZxWriteRule.admin
                      ? 'Maintainers (only the admin signs)'
                      : 'Maintainers',
                ),
                if (policy.maintainers.isEmpty)
                  Text('none', style: mono)
                else
                  for (final m in policy.maintainers)
                    SelectableText(npubEncode(m), style: mono),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('seal-full-check'),
          onPressed: _checking ? null : _fullCheck,
          child: Text(_checking ? 'Checking...' : 'Full check'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
