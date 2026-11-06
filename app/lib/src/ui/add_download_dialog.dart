import 'dart:async';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_controller.dart';

class AddDownloadDialog extends StatefulWidget {
  const AddDownloadDialog({super.key, this.initialUrl});

  final String? initialUrl;

  @override
  State<AddDownloadDialog> createState() => _AddDownloadDialogState();
}

class _AddDownloadDialogState extends State<AddDownloadDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _url;
  final _name = TextEditingController();
  final _sha256 = TextEditingController();
  bool _advanced = false;
  bool _mediaMode = false;
  bool _wholePlaylist = false;
  bool _busy = false;
  late MediaFormat _format;
  int? _maxHeight;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl ?? '');
    final settings = context.read<AppController>().settings;
    _format = settings.mediaFormat;
    _maxHeight = settings.mediaMaxHeight;
    if (_shouldEnableMedia()) _enableMedia();
    _url.addListener(_detectMedia);
    if (widget.initialUrl == null) _fillFromClipboard();
  }

  /// Video sitesi bağlantısı yapıştırılınca Video/Ses kipine geçer.
  void _detectMedia() {
    if (_shouldEnableMedia()) setState(_enableMedia);
  }

  bool _shouldEnableMedia() {
    if (!isMediaSupported || _mediaMode) return false;
    final uri = Uri.tryParse(_url.text.trim());
    return uri != null && isLikelyMediaUrl(uri);
  }

  void _enableMedia() {
    final uri = Uri.parse(_url.text.trim());
    _mediaMode = true;
    _wholePlaylist = uri.queryParameters.containsKey('list');
  }

  /// Panoda bağlantı varsa adres alanına önerir.
  Future<void> _fillFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text == null || !mounted || _url.text.isNotEmpty) return;
    if (_validateUrl(text) == null) _url.text = text;
  }

  @override
  void dispose() {
    _url.removeListener(_detectMedia);
    _url.dispose();
    _name.dispose();
    _sha256.dispose();
    super.dispose();
  }

  String? _validateUrl(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return 'Bir adres girin';
    final uri = Uri.tryParse(text);
    if (uri == null) return 'Geçersiz adres';
    if (isTorrentUri(uri)) return null;
    try {
      validateDownloadUri(uri);
    } on InvalidUrlException {
      return 'Adres http://, https:// veya magnet: ile başlamalı';
    }
    return null;
  }

  String? _validateSha(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty || isValidSha256(text)) return null;
    return '64 karakterlik onaltılık özet olmalı';
  }

  Future<void> _pickTorrent() async {
    final controller = context.read<AppController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Torrent',
            extensions: ['torrent'],
            mimeTypes: ['application/x-bittorrent'],
            uniformTypeIdentifiers: ['public.data'],
          ),
        ],
      );
      if (file == null) return;
      final uri = await controller.importTorrentFile(file.path);
      if (mounted) _url.text = uri.toString();
    } on FileSystemException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Dosya okunamadı: ${e.message}')),
      );
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    final controller = context.read<AppController>();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final url = Uri.parse(_url.text.trim());
    if (!_mediaMode) {
      final name = _name.text.trim();
      final sha = _sha256.text.trim();
      controller.addDownload(
        url,
        fileName: name.isEmpty ? null : name,
        expectedSha256: sha.isEmpty ? null : sha,
      );
      navigator.pop();
      return;
    }
    final media = MediaOptions(format: _format, maxHeight: _maxHeight);
    unawaited(
      controller.updateSettings((s) {
        s.mediaFormat = _format;
        s.mediaMaxHeight = _maxHeight;
      }),
    );
    if (!_wholePlaylist) {
      controller.addDownload(url, media: media);
      navigator.pop();
      return;
    }
    setState(() => _busy = true);
    try {
      final count = await controller.addMediaPlaylist(url, media);
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('$count video eklendi')));
    } on DownloadException catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Widget _mediaFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        DropdownButtonFormField<MediaFormat>(
          initialValue: _format,
          decoration: const InputDecoration(labelText: 'Biçim'),
          items: const [
            DropdownMenuItem(
              value: MediaFormat.mp4,
              child: Text('MP4 (video)'),
            ),
            DropdownMenuItem(
              value: MediaFormat.mp3,
              child: Text('MP3 (yalnızca ses)'),
            ),
          ],
          onChanged: (value) => setState(() => _format = value!),
        ),
        if (_format == MediaFormat.mp4) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int?>(
            initialValue: _maxHeight,
            decoration: const InputDecoration(labelText: 'Kalite'),
            items: const [
              DropdownMenuItem(child: Text('En iyi')),
              DropdownMenuItem(value: 1080, child: Text('1080p')),
              DropdownMenuItem(value: 720, child: Text('720p')),
              DropdownMenuItem(value: 480, child: Text('480p')),
            ],
            onChanged: (value) => setState(() => _maxHeight = value),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Oynatma listesinin tamamı'),
          subtitle: const Text('Her video ayrı indirme olarak eklenir.'),
          value: _wholePlaylist,
          onChanged: (value) => setState(() => _wholePlaylist = value),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('İndirme ekle'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isMediaSupported) ...[
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('Dosya')),
                      ButtonSegment(value: true, label: Text('Video / Ses')),
                    ],
                    selected: {_mediaMode},
                    onSelectionChanged: (value) =>
                        setState(() => _mediaMode = value.single),
                  ),
                  const SizedBox(height: 8),
                ],
                TextFormField(
                  controller: _url,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Adres veya magnet bağlantısı',
                    hintText: 'https://ornek.com/dosya.zip',
                  ),
                  validator: _validateUrl,
                  onFieldSubmitted: (_) => unawaited(_submit()),
                ),
                if (_mediaMode) _mediaFields(),
                const SizedBox(height: 8),
                if (!_mediaMode)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: _pickTorrent,
                      icon: const Icon(Icons.file_open_outlined),
                      label: const Text('Torrent dosyası seç'),
                    ),
                  ),
                if (_mediaMode)
                  const SizedBox.shrink()
                else if (!_advanced)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton(
                      onPressed: () => setState(() => _advanced = true),
                      child: const Text('Dosya adı ve SHA-256'),
                    ),
                  )
                else ...[
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Dosya adı (isteğe bağlı)',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _sha256,
                    decoration: const InputDecoration(
                      labelText: 'Beklenen SHA-256 (isteğe bağlı)',
                    ),
                    validator: _validateSha,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          onPressed: _busy ? null : () => unawaited(_submit()),
          child: Text(_busy ? 'Liste okunuyor…' : 'İndir'),
        ),
      ],
    );
  }
}
