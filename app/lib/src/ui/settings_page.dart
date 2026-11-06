import 'dart:async';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  Future<void> _pickFolder(AppController controller) async {
    final path = await getDirectoryPath(
      initialDirectory: controller.settings.downloadDirectory,
    );
    if (path != null) {
      await controller.updateSettings((s) => s.downloadDirectory = path);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          ListTile(
            title: Text('Parça sayısı: ${settings.segments}'),
            subtitle: Slider(
              value: settings.segments.toDouble(),
              min: 1,
              max: maxSegments.toDouble(),
              divisions: maxSegments - 1,
              label: '${settings.segments}',
              onChanged: (value) => unawaited(
                controller.updateSettings((s) => s.segments = value.round()),
              ),
            ),
          ),
          ListTile(
            title: Text('Aynı anda indirme: ${settings.maxConcurrent}'),
            subtitle: Slider(
              value: settings.maxConcurrent.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '${settings.maxConcurrent}',
              onChanged: (value) => unawaited(
                controller.updateSettings(
                  (s) => s.maxConcurrent = value.round(),
                ),
              ),
            ),
          ),
          const Divider(),
          const _SectionHeader('Bağlantı'),
          ListTile(
            title: Text(
              'Bağlantı zaman aşımı: ${settings.connectionTimeoutSeconds} sn',
            ),
            subtitle: Slider(
              value: settings.connectionTimeoutSeconds.toDouble(),
              min: 5,
              max: 120,
              divisions: 23,
              label: '${settings.connectionTimeoutSeconds} sn',
              onChanged: (value) => unawaited(
                controller.updateSettings(
                  (s) => s.connectionTimeoutSeconds = value.round(),
                ),
              ),
            ),
          ),
          ListTile(
            title: Text('Yeniden deneme: ${settings.maxAttempts}'),
            subtitle: Slider(
              value: settings.maxAttempts.toDouble(),
              min: 1,
              max: 20,
              divisions: 19,
              label: '${settings.maxAttempts}',
              onChanged: (value) => unawaited(
                controller.updateSettings((s) => s.maxAttempts = value.round()),
              ),
            ),
          ),
          const _ConnectionFields(),
          const Divider(),
          const _SectionHeader('Torrent'),
          ListTile(
            title: Text('Eş bağlantısı sınırı: ${settings.torrentMaxPeers}'),
            subtitle: Slider(
              value: settings.torrentMaxPeers.toDouble(),
              min: 10,
              max: 300,
              divisions: 29,
              label: '${settings.torrentMaxPeers}',
              onChanged: (value) => unawaited(
                controller.updateSettings(
                  (s) => s.torrentMaxPeers = value.round(),
                ),
              ),
            ),
          ),
          const _TorrentPortField(),
          SwitchListTile(
            title: const Text('DHT ile eş ara'),
            subtitle: const Text('İzleyicisiz torrentlerde eş bulmayı sağlar.'),
            value: settings.torrentDht,
            onChanged: (value) => unawaited(
              controller.updateSettings((s) => s.torrentDht = value),
            ),
          ),
          SwitchListTile(
            title: const Text('Yönlendiricide port aç (UPnP)'),
            subtitle: const Text(
              'Gelen bağlantıları artırır, ama modemde kalıcı bir yönlendirme '
              'kaydı bırakabilir. Gerekmedikçe kapalı tutun.',
            ),
            value: settings.torrentPortForwarding,
            onChanged: (value) => unawaited(
              controller.updateSettings((s) => s.torrentPortForwarding = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'Torrent indirirken IP adresiniz diğer eşlere görünür ve parçalar '
              'onlara da gönderilir. Hız sınırı ve HTTP proxy torrent '
              'bağlantılarına uygulanmaz.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(),
          if (Platform.isAndroid)
            const ListTile(
              title: Text('İndirme klasörü'),
              subtitle: Text(
                'Biten dosyalar telefonun İndirilenler klasörüne aktarılır.',
              ),
            )
          else
            ListTile(
              title: const Text('İndirme klasörü'),
              subtitle: Text(settings.downloadDirectory),
              trailing: const Icon(Icons.folder_open),
              onTap: () => unawaited(_pickFolder(controller)),
            ),
          if (AppController.isDesktop) ...[
            const Divider(),
            const _CaptureSection(),
          ],
        ],
      ),
    );
  }
}

class _TorrentPortField extends StatefulWidget {
  const _TorrentPortField();

  @override
  State<_TorrentPortField> createState() => _TorrentPortFieldState();
}

class _TorrentPortFieldState extends State<_TorrentPortField> {
  late final AppController _controller;
  late final TextEditingController _port;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = context.read<AppController>();
    final port = _controller.settings.torrentListenPort;
    _port = TextEditingController(text: port == 0 ? '' : '$port');
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  void _apply(String text) {
    final trimmed = text.trim();
    final port = trimmed.isEmpty ? 0 : int.tryParse(trimmed);
    if (port == null || (port != 0 && (port < 1024 || port > 65535))) {
      setState(() => _error = 'Port 1024 ile 65535 arasında olmalı');
      return;
    }
    setState(() => _error = null);
    unawaited(_controller.updateSettings((s) => s.torrentListenPort = port));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: _port,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: 'Gelen bağlantı portu',
          hintText: 'Boş bırakılırsa otomatik',
          errorText: _error,
        ),
        onChanged: _apply,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

/// Hız sınırı ve proxy alanları. Odak çıkınca veya Enter ile uygulanır.
class _ConnectionFields extends StatefulWidget {
  const _ConnectionFields();

  @override
  State<_ConnectionFields> createState() => _ConnectionFieldsState();
}

class _ConnectionFieldsState extends State<_ConnectionFields> {
  late final AppController _controller;
  late final TextEditingController _limit;
  late final TextEditingController _proxy;
  late final FocusNode _limitFocus;
  late final FocusNode _proxyFocus;
  String? _proxyError;

  @override
  void initState() {
    super.initState();
    _controller = context.read<AppController>();
    final settings = _controller.settings;
    _limit = TextEditingController(
      text: settings.speedLimitKiB == 0 ? '' : '${settings.speedLimitKiB}',
    );
    _proxy = TextEditingController(text: settings.proxy ?? '');
    _limitFocus = FocusNode()..addListener(_onLimitFocus);
    _proxyFocus = FocusNode()..addListener(_onProxyFocus);
  }

  void _onLimitFocus() {
    if (!_limitFocus.hasFocus) unawaited(_applyLimit());
  }

  void _onProxyFocus() {
    if (!_proxyFocus.hasFocus) unawaited(_applyProxy());
  }

  @override
  void dispose() {
    // Geri tuşuyla çıkılırsa odak olayı gelmeyebilir: yazılanı kaybetme.
    unawaited(_applyLimit());
    if (isValidProxy(_proxy.text.trim()) || _proxy.text.trim().isEmpty) {
      unawaited(_saveProxy(_proxy.text.trim()));
    }
    _limitFocus.dispose();
    _proxyFocus.dispose();
    _limit.dispose();
    _proxy.dispose();
    super.dispose();
  }

  Future<void> _applyLimit() {
    final value = int.tryParse(_limit.text.trim()) ?? 0;
    final limit = value.clamp(0, 10 * 1024 * 1024);
    return _controller.updateSettings((s) => s.speedLimitKiB = limit);
  }

  Future<void> _saveProxy(String text) =>
      _controller.updateSettings((s) => s.proxy = text.isEmpty ? null : text);

  Future<void> _applyProxy() async {
    final text = _proxy.text.trim();
    if (text.isNotEmpty && !isValidProxy(text)) {
      setState(() => _proxyError = 'sunucu:port biçiminde olmalı');
      return;
    }
    setState(() => _proxyError = null);
    await _saveProxy(text);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _limit,
            focusNode: _limitFocus,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(
              labelText: 'İndirme başına hız sınırı (KiB/sn)',
              hintText: 'Boş bırakılırsa sınırsız',
            ),
            onSubmitted: (_) => unawaited(_applyLimit()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _proxy,
            focusNode: _proxyFocus,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'HTTP proxy',
              hintText: 'proxy.ornek.com:3128',
              errorText: _proxyError,
            ),
            onSubmitted: (_) => unawaited(_applyProxy()),
          ),
          const SizedBox(height: 8),
          Text(
            'Bağlantı ayarları yeni indirmelerde ve duraklatılıp '
            'sürdürülenlerde geçerli olur.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _CaptureSection extends StatefulWidget {
  const _CaptureSection();

  @override
  State<_CaptureSection> createState() => _CaptureSectionState();
}

class _CaptureSectionState extends State<_CaptureSection> {
  late final TextEditingController _port;

  @override
  void initState() {
    super.initState();
    _port = TextEditingController(
      text: '${context.read<AppController>().settings.capturePort}',
    );
  }

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _applyPort(AppController controller) async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      _port.text = '${controller.settings.capturePort}';
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Port 1024 ile 65535 arasında olmalı')),
      );
      return;
    }
    await controller.updateSettings((s) => s.capturePort = port);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final settings = controller.settings;
    final theme = Theme.of(context);
    final status = !settings.captureEnabled
        ? 'Kapalı'
        : controller.captureRunning
        ? 'Çalışıyor: 127.0.0.1:${settings.capturePort}'
        : (controller.captureError?.message ?? 'Başlatılamadı');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          title: const Text('Tarayıcı eklentisinden link al'),
          subtitle: Text(status),
          value: settings.captureEnabled,
          onChanged: (value) => unawaited(
            controller.updateSettings((s) => s.captureEnabled = value),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: TextField(
            controller: _port,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: const InputDecoration(labelText: 'Port'),
            onSubmitted: (_) => unawaited(_applyPort(controller)),
          ),
        ),
        ListTile(
          title: const Text('Eşleştirme anahtarı'),
          subtitle: SelectableText(
            settings.captureToken,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
          trailing: IconButton(
            tooltip: 'Kopyala',
            icon: const Icon(Icons.copy),
            onPressed: () {
              unawaited(
                Clipboard.setData(ClipboardData(text: settings.captureToken)),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Anahtar kopyalandı')),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            'Bu anahtarı Chrome eklentisinin ayarlarına yapıştırın. '
            'Anahtarı bilen yerel programlar indirme başlatabilir.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8),
          child: TextButton(
            onPressed: () => unawaited(controller.regenerateCaptureToken()),
            child: const Text('Anahtarı yenile'),
          ),
        ),
      ],
    );
  }
}
