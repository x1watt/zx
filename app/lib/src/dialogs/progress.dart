// Runs an archive operation with a progress dialog (percent, current file,
// speed over the last 20 seconds, elapsed time and the time left, Cancel). The work itself runs in the background isolates of
// ZxArchive; this isolate only redraws the dialog from the throttled
// progress events.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zx/zx.dart';

import '../ui/format_utils.dart';

/// Progress of one operation, shared by the dialog and the caller.
class OperationProgress extends ChangeNotifier {
  final String title;
  final Stopwatch _watch = Stopwatch()..start();
  ZxProgress? _last;
  final ZxCancelToken cancel = ZxCancelToken();

  /// The time since the start (tests give a fake clock).
  final Duration Function()? _clock;

  // (time, done bytes) of the last [window], for the recent speed
  final List<(Duration, int)> _samples = [];

  /// The span of the recent speed.
  static const window = Duration(seconds: 20);

  OperationProgress(this.title, {Duration Function()? clock})
    : _clock = clock; // ignore: prefer_initializing_formals

  ZxProgress? get last => _last;
  Duration get elapsed => _clock?.call() ?? _watch.elapsed;

  void update(ZxProgress p) {
    _last = p;
    final now = elapsed;
    _samples.add((now, p.doneBytes));
    while (_samples.length > 2 && now - _samples.first.$1 > window) {
      _samples.removeAt(0);
    }
    notifyListeners();
  }

  /// Bytes per second since the start.
  double get averageSpeed {
    final s = elapsed.inMicroseconds / 1e6;
    final d = _last?.doneBytes ?? 0;
    return s <= 0.2 ? 0 : d / s;
  }

  /// Bytes per second over the last [window] (the average until then).
  double get speed {
    if (_samples.length < 2) return averageSpeed;
    final a = _samples.first, b = _samples.last;
    final s = (b.$1 - a.$1).inMicroseconds / 1e6;
    if (s < 2) return averageSpeed;
    final v = (b.$2 - a.$2) / s;
    return v > 0 ? v : averageSpeed;
  }

  /// The time left at the recent speed, or null when unknown or too early
  /// to tell (the first 3 seconds).
  Duration? get eta {
    final p = _last;
    if (p == null || p.totalBytes <= 0) return null;
    if (elapsed < const Duration(seconds: 3)) return null;
    final v = speed;
    if (v <= 0) return null;
    final left = p.totalBytes - p.doneBytes;
    if (left <= 0) return Duration.zero;
    return Duration(milliseconds: (left / v * 1000).round());
  }
}

/// "0:42", "12:05", "1:02:03".
String formatElapsed(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// "about 12 min left", "about 2 h 5 min left", "a few seconds left".
String etaText(Duration d) {
  final s = d.inSeconds;
  if (s < 10) return 'a few seconds left';
  if (s < 90) return 'about ${(s / 5).round() * 5} s left';
  final min = (s / 60).round();
  if (min < 90) return 'about $min min left';
  final h = min ~/ 60, rest = min % 60;
  return rest == 0 ? 'about $h h left' : 'about $h h $rest min left';
}

/// Runs [body] and shows the progress dialog when it takes more than
/// [delay]. Errors of [body] come out unchanged (cancel is a
/// SevenZipException of kind cancelled).
Future<T> runWithProgress<T>(
  BuildContext context,
  String title,
  Future<T> Function(OperationProgress progress) body, {
  Duration delay = const Duration(milliseconds: 250),
}) async {
  final progress = OperationProgress(title);
  final nav = Navigator.of(context);
  DialogRoute<void>? route;
  // the route of the caller: while a question of the operation (password,
  // overwrite) is on top of it, the progress waits, so that it never
  // covers the question
  final owner = ModalRoute.of(context);
  var finished = false;
  Timer? timer;
  void show() {
    if (finished || !nav.mounted) return;
    if (owner != null && !owner.isCurrent) {
      timer = Timer(const Duration(milliseconds: 200), show);
      return;
    }
    route = DialogRoute<void>(
      context: nav.context,
      barrierDismissible: false,
      builder: (_) => ProgressDialog(progress: progress),
    );
    nav.push(route!);
  }

  timer = Timer(delay, show);
  try {
    return await body(progress);
  } finally {
    finished = true;
    timer?.cancel();
    final r = route;
    if (r != null && r.isActive && nav.mounted) nav.removeRoute(r);
  }
}

class ProgressDialog extends StatefulWidget {
  final OperationProgress progress;
  const ProgressDialog({super.key, required this.progress});

  @override
  State<ProgressDialog> createState() => _ProgressDialogState();
}

class _ProgressDialogState extends State<ProgressDialog> {
  // redraws the elapsed time between progress events (a slow zcm block)
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.progress;
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        key: const Key('progress-dialog'),
        title: Text(progress.title),
        content: SizedBox(
          width: 460,
          child: ListenableBuilder(
            listenable: progress,
            builder: (context, _) {
              final p = progress.last;
              final f = p?.fraction;
              final speed = progress.speed;
              final eta = progress.eta;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p?.currentFile ?? 'Working...',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: f ?? 0, minHeight: 8),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        f == null ? '' : '${(f * 100).floor()}%',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          p == null
                              ? ''
                              : '${formatBytes(p.doneBytes)}'
                                    '${p.totalBytes > 0 ? ' of ${formatBytes(p.totalBytes)}' : ''}',
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                      ),
                      if (speed > 0)
                        Text(
                          '${formatBytes(speed.round())}/s',
                          key: const Key('progress-speed'),
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                    ],
                  ),
                  if (progress.elapsed >= const Duration(seconds: 3)) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(
                          'Elapsed ${formatElapsed(progress.elapsed)}',
                          key: const Key('progress-elapsed'),
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                        const Spacer(),
                        if (eta != null)
                          Text(
                            etaText(eta),
                            key: const Key('progress-eta'),
                            style: TextStyle(color: cs.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        actions: [
          TextButton(
            key: const Key('progress-cancel'),
            onPressed: () => progress.cancel.cancel(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}
