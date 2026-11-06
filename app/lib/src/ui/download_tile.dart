import 'package:dm_core/dm_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_controller.dart';
import '../format.dart';
import 'download_actions.dart';

class DownloadTile extends StatelessWidget {
  const DownloadTile({
    super.key,
    required this.task,
    required this.onTap,
    this.selected = false,
  });

  final DownloadTask task;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    // Her ilerleme olayında kuyruk üzerinden yeniden çizilir.
    context.watch<AppController>();
    final theme = Theme.of(context);
    final progress = task.current;
    final failed = progress.state == DownloadState.failed;
    final name =
        progress.fileName ??
        (task.request.url.pathSegments.isEmpty
            ? task.request.url.host
            : task.request.url.pathSegments.last);

    return ListTile(
      selected: selected,
      onTap: onTap,
      leading: Icon(_icon(progress.state)),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          _bar(context, progress),
          const SizedBox(height: 4),
          Text(
            failed && progress.error != null
                ? errorMessage(progress.error!)
                : progressSummary(progress),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: failed ? TextStyle(color: theme.colorScheme.error) : null,
          ),
        ],
      ),
      trailing: DownloadActions(task: task),
    );
  }

  Widget _bar(BuildContext context, DownloadProgress progress) {
    final colors = Theme.of(context).colorScheme;
    return switch (progress.state) {
      DownloadState.completed => LinearProgressIndicator(
        value: 1,
        color: colors.tertiary,
      ),
      DownloadState.probing ||
      DownloadState.verifying => const LinearProgressIndicator(),
      DownloadState.downloading => LinearProgressIndicator(
        value: progress.fraction,
      ),
      DownloadState.failed => LinearProgressIndicator(
        value: progress.fraction ?? 0,
        color: colors.error,
      ),
      _ => LinearProgressIndicator(
        value: progress.fraction ?? 0,
        color: colors.outline,
      ),
    };
  }

  IconData _icon(DownloadState state) => switch (state) {
    DownloadState.completed => Icons.check_circle_outline,
    DownloadState.failed => Icons.error_outline,
    DownloadState.paused => Icons.pause_circle_outline,
    DownloadState.canceled => Icons.cancel_outlined,
    DownloadState.queued => Icons.schedule,
    _ => Icons.downloading,
  };
}
