import 'dart:async';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_controller.dart';
import '../format.dart';
import 'download_actions.dart';

/// Seçili indirmenin ayrıntıları: parça çubuğu, adres, klasör, özet.
class DownloadDetail extends StatelessWidget {
  const DownloadDetail({super.key, required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final theme = Theme.of(context);
    final p = task.current;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SelectableText(
          p.fileName ?? task.request.url.toString(),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 4),
        Text(stateLabel(p.state), style: theme.textTheme.bodyMedium),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: DownloadActions(task: task),
        ),
        if (p.segments.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text(
            '${p.segments.length} parça  •  ${p.activeConnections} bağlantı',
            style: theme.textTheme.labelMedium,
          ),
          const SizedBox(height: 6),
          SegmentBar(progress: p),
        ],
        const SizedBox(height: 16),
        _Field('İlerleme', progressSummary(p)),
        _Field('Adres', task.request.url.toString(), copyable: true),
        if (p.filePath != null)
          if (p.state == DownloadState.completed &&
              !File(p.filePath!).existsSync())
            Platform.isAndroid
                ? const _Field('Konum', 'İndirilenler klasörü')
                : const _Field('Konum', 'Dosya taşınmış veya silinmiş')
          else
            _Field('Konum', p.filePath!, copyable: true),
        if (!p.resumable)
          const _Field(
            'Devam',
            'Sunucu kaldığı yerden devamı desteklemiyor. '
                'Duraklatılırsa indirme baştan başlar.',
          ),
        if (p.restarts > 0)
          _Field(
            'Yeniden başlatma',
            'Sunucudaki dosya değiştiği için ${p.restarts} kez baştan başladı.',
          ),
        if (p.sha256 != null) _Field('SHA-256', p.sha256!, copyable: true),
        if (p.error != null) _Field('Hata', errorMessage(p.error!)),
        if (p.state == DownloadState.completed &&
            p.filePath != null &&
            AppController.isDesktop &&
            File(p.filePath!).existsSync())
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: () =>
                  unawaited(controller.revealInFolder(p.filePath!)),
              icon: const Icon(Icons.folder_open),
              label: const Text('Klasörde göster'),
            ),
          ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.copyable = false});

  final String label;
  final String value;
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(value),
              ],
            ),
          ),
          if (copyable)
            IconButton(
              tooltip: 'Kopyala',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () =>
                  unawaited(Clipboard.setData(ClipboardData(text: value))),
            ),
        ],
      ),
    );
  }
}

/// Her parçayı dosyadaki gerçek konumu ve doluluğuyla çizer.
class SegmentBar extends StatelessWidget {
  const SegmentBar({super.key, required this.progress});

  final DownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Parça durumu',
      value: progress.fraction == null
          ? null
          : '%${(progress.fraction! * 100).round()}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 14,
          width: double.infinity,
          child: CustomPaint(
            painter: _SegmentPainter(
              segments: progress.segments,
              total: progress.totalBytes,
              track: colors.surfaceContainerHighest,
              fill: colors.primary,
              gap: colors.surface,
            ),
          ),
        ),
      ),
    );
  }
}

class _SegmentPainter extends CustomPainter {
  _SegmentPainter({
    required this.segments,
    required this.total,
    required this.track,
    required this.fill,
    required this.gap,
  });

  final List<SegmentProgress> segments;
  final int? total;
  final Color track;
  final Color fill;
  final Color gap;

  @override
  void paint(Canvas canvas, Size size) {
    final bytes = total;
    canvas.drawRect(Offset.zero & size, Paint()..color = track);
    if (bytes == null || bytes <= 0) return;
    final fillPaint = Paint()..color = fill;
    final gapPaint = Paint()..color = gap;
    final scale = size.width / bytes;
    for (final segment in segments) {
      final left = segment.start * scale;
      canvas.drawRect(
        Rect.fromLTWH(left, 0, segment.downloaded * scale, size.height),
        fillPaint,
      );
      if (segment.start > 0) {
        canvas.drawRect(Rect.fromLTWH(left, 0, 1, size.height), gapPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SegmentPainter oldDelegate) => true;
}
