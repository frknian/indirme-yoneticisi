import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:dm_core/dm_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app_controller.dart';
import 'add_download_dialog.dart';
import 'download_detail.dart';
import 'download_tile.dart';
import 'logo.dart';
import 'settings_page.dart';

/// Bu genişliğin üstünde liste + yan panel gösterilir.
const double wideLayoutBreakpoint = 840;

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<String>? _incoming;
  AppLifecycleListener? _lifecycle;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    final controller = context.read<AppController>();
    _incoming = controller.incomingUrls.listen(_showAddDialog);
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        await controller.shutdown();
        return AppExitResponse.exit;
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final pending = controller.takePendingUrl();
      if (pending != null) _showAddDialog(pending);
      final error = controller.startupError;
      if (error != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kayıtlı liste okunamadı: ${error.message}')),
        );
      }
    });
  }

  @override
  void dispose() {
    unawaited(_incoming?.cancel());
    _lifecycle?.dispose();
    super.dispose();
  }

  void _showAddDialog([String? initialUrl]) {
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => AddDownloadDialog(initialUrl: initialUrl),
      ),
    );
  }

  void _openSettings() {
    unawaited(
      Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final tasks = controller.tasks;
    final hasPausable = tasks.any(
      (t) => t.state.isActive || t.state == DownloadState.queued,
    );
    final hasResumable = tasks.any((t) => t.state == DownloadState.paused);

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        leading: const Padding(
          padding: EdgeInsets.only(left: 12),
          child: AppLogo(size: 32),
        ),
        title: const Text('İndirme Yöneticisi'),
        actions: [
          IconButton(
            tooltip: 'Tümünü duraklat',
            icon: const Icon(Icons.pause_circle_outline),
            onPressed: hasPausable
                ? () => unawaited(controller.pauseAll())
                : null,
          ),
          IconButton(
            tooltip: 'Tümünü sürdür',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: hasResumable ? controller.resumeAll : null,
          ),
          IconButton(
            tooltip: 'Ayarlar',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        icon: const Icon(Icons.add),
        label: const Text('İndirme ekle'),
      ),
      body: Column(
        children: [
          if (controller.foregroundBlocked && Platform.isAndroid)
            const _Banner(
              text:
                  'Sistem arka plan servisine izin vermedi. '
                  'Uygulamadan çıkarsanız indirmeler durabilir.',
            ),
          if (controller.publishError != null)
            _Banner(
              text: controller.publishError!,
              action: TextButton(
                onPressed: controller.clearPublishError,
                child: const Text('Kapat'),
              ),
            ),
          if (controller.captureError != null)
            _Banner(
              text:
                  'Tarayıcı bağlantısı başlatılamadı. '
                  'Ayarlardan başka bir port deneyin.',
              action: TextButton(
                onPressed: _openSettings,
                child: const Text('Ayarlar'),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= wideLayoutBreakpoint;
                return wide ? _wide(tasks) : _list(tasks, wide: false);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _wide(List<DownloadTask> tasks) {
    final selected = tasks.where((t) => t.id == _selectedId).firstOrNull;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: 3, child: _list(tasks, wide: true)),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 360,
          child: selected == null
              ? const _DetailPlaceholder()
              : DownloadDetail(key: ValueKey(selected.id), task: selected),
        ),
      ],
    );
  }

  Widget _list(List<DownloadTask> tasks, {required bool wide}) {
    if (tasks.isEmpty) return const _EmptyState();
    return ListView.separated(
      padding: const EdgeInsets.only(top: 8, bottom: 96),
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final task = tasks[index];
        return DownloadTile(
          key: ValueKey(task.id),
          task: task,
          selected: wide && task.id == _selectedId,
          onTap: () {
            if (wide) {
              setState(() => _selectedId = task.id);
            } else {
              unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => _DetailRoute(task: task),
                  ),
                ),
              );
            }
          },
        );
      },
    );
  }
}

/// Mobil ayrıntı sayfası; görev listeden kaldırılınca kendini kapatır.
class _DetailRoute extends StatelessWidget {
  const _DetailRoute({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final exists = context.watch<AppController>().tasks.contains(task);
    if (!exists) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.of(context).maybePop();
      });
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Ayrıntılar')),
      body: exists ? DownloadDetail(task: task) : const SizedBox.shrink(),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                text,
                style: TextStyle(color: colors.onErrorContainer),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppLogo(size: 72),
            const SizedBox(height: 16),
            Text('Henüz indirme yok', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Başlamak için bir bağlantı ekleyin.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailPlaceholder extends StatelessWidget {
  const _DetailPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Text(
        'Ayrıntılar için bir indirme seçin',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
