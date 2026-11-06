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

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl ?? '');
    if (widget.initialUrl == null) _fillFromClipboard();
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

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final name = _name.text.trim();
    final sha = _sha256.text.trim();
    context.read<AppController>().addDownload(
      Uri.parse(_url.text.trim()),
      fileName: name.isEmpty ? null : name,
      expectedSha256: sha.isEmpty ? null : sha,
    );
    Navigator.of(context).pop();
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
                  onFieldSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: _pickTorrent,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Torrent dosyası seç'),
                  ),
                ),
                if (!_advanced)
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
        FilledButton(onPressed: _submit, child: const Text('İndir')),
      ],
    );
  }
}
