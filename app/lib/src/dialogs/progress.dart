// Runs an archive operation with a progress dialog (percent, current file,
// speed, Cancel). The work itself runs in the background isolates of
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

  OperationProgress(this.title);

  ZxProgress? get last => _last;
  Duration get elapsed => _watch.elapsed;

  void update(ZxProgress p) {
    _last = p;
    notifyListeners();
  }

  /// Bytes per second since the start.
  double get speed {
    final s = _watch.elapsedMicroseconds / 1e6;
    final d = _last?.doneBytes ?? 0;
    return s <= 0.2 ? 0 : d / s;
  }
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

class ProgressDialog extends StatelessWidget {
  final OperationProgress progress;
  const ProgressDialog({super.key, required this.progress});

  @override
  Widget build(BuildContext context) {
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
                          style: TextStyle(color: cs.onSurfaceVariant),
                        ),
                    ],
                  ),
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
