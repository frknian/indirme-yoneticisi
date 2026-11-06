import 'dart:async';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_controller.dart';

/// Duruma uygun duraklat, devam, iptal ve kaldır düğmeleri.
class DownloadActions extends StatelessWidget {
  const DownloadActions({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final controller = context.read<AppController>();
    final state = task.state;
    final canPause = state.isActive || state == DownloadState.queued;
    final canResume =
        state == DownloadState.paused || state == DownloadState.failed;
    final canCancel = canPause || canResume;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canPause)
          IconButton(
            tooltip: task.current.resumable
                ? 'Duraklat'
                : 'Duraklat (sunucu devamı desteklemiyor, baştan başlar)',
            icon: const Icon(Icons.pause),
            onPressed: () => unawaited(controller.pause(task)),
          ),
        if (canResume)
          IconButton(
            tooltip: state == DownloadState.failed
                ? 'Yeniden dene'
                : 'Devam et',
            icon: Icon(
              state == DownloadState.failed ? Icons.refresh : Icons.play_arrow,
            ),
            onPressed: () => controller.resume(task),
          ),
        if (canCancel)
          IconButton(
            tooltip: 'İptal et',
            icon: const Icon(Icons.close),
            onPressed: () => unawaited(controller.cancel(task)),
          ),
        if (state.isTerminal)
          IconButton(
            tooltip: 'Listeden kaldır',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => unawaited(_confirmRemove(context, controller)),
          ),
      ],
    );
  }

  Future<void> _confirmRemove(
    BuildContext context,
    AppController controller,
  ) async {
    // Android'de dosya İndirilenler'e taşındıysa burada silinecek bir şey yoktur;
    // herkese açık kopya kullanıcınındır ve seçenek olarak sunulmaz.
    final path = task.current.filePath;
    final fileExists =
        path != null &&
        FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;
    if (task.state != DownloadState.completed || !fileExists) {
      await controller.remove(task);
      return;
    }
    final deleteFile = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Listeden kaldırılsın mı?'),
        content: Text(task.current.fileName ?? task.request.url.toString()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Dosyayı da sil'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Yalnızca kaldır'),
          ),
        ],
      ),
    );
    if (deleteFile == null) return;
    try {
      await controller.remove(task, deleteFile: deleteFile);
    } on DownloadException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
  }
}
