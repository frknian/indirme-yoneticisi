import 'dart:async';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../app_controller.dart';
import '../format.dart';

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

  /// Kullanıcının tercihi. [_maxHeight] videoya uyarlanır; kaydedilen tercih uyarlanmaz,
  /// yoksa 720p'lik tek bir video sonraki indirmeleri de 720p'ye düşürürdü.
  int? _preferredHeight;
  List<MediaQuality> _qualities = const [];
  bool _loadingQualities = false;
  String? _qualityNote;
  String? _probedUrl;
  Timer? _probeDelay;

  /// Kullanıcı kipi kendisi seçtiyse otomatik algılama değiştirmez.
  bool _modeChosen = false;
  Timer? _pageCheckDelay;
  int _pageCheckToken = 0;
  int _probeToken = 0;

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl ?? '');
    final settings = context.read<AppController>().settings;
    _format = settings.mediaFormat;
    _maxHeight = settings.mediaMaxHeight;
    _preferredHeight = _maxHeight;
    if (_shouldEnableMedia()) _enableMedia();
    _updateQualityProbe();
    _updatePageCheck();
    _url.addListener(_detectMedia);
    if (widget.initialUrl == null) _fillFromClipboard();
  }

  /// Video sitesi bağlantısı yapıştırılınca Video/Ses kipine geçer.
  void _detectMedia() {
    setState(() {
      if (!_modeChosen && !_isKnownVideoSite()) {
        // Yapıştırılan yeni adres dosya olabilir: önceki otomatik seçim taşınmasın.
        _mediaMode = false;
        _wholePlaylist = false;
      }
      if (_shouldEnableMedia()) _enableMedia();
      _updateQualityProbe();
      _updatePageCheck();
    });
  }

  bool _isKnownVideoSite() {
    final uri = Uri.tryParse(_url.text.trim());
    return uri != null && isLikelyMediaUrl(uri);
  }

  /// Bilinen video sitesi değilse sunucuya sorar; web sayfasıysa Video / Ses kipine geçer.
  void _updatePageCheck() {
    _pageCheckDelay?.cancel();
    final token = ++_pageCheckToken;
    final text = _url.text.trim();
    final uri = Uri.tryParse(text);
    if (!isMediaSupported ||
        _modeChosen ||
        _mediaMode ||
        uri == null ||
        !(uri.isScheme('http') || uri.isScheme('https')) ||
        uri.host.isEmpty) {
      return;
    }
    _pageCheckDelay = Timer(const Duration(milliseconds: 600), () async {
      final isPage = await context.read<AppController>().isWebPage(uri);
      if (!isPage || !mounted || token != _pageCheckToken || _modeChosen) {
        return;
      }
      setState(() {
        _enableMedia();
        _updateQualityProbe();
      });
    });
  }

  /// Adres veya seçenekler değişince gerekiyorsa kalite sorgusunu planlar. Yazarken her
  /// harfte yt-dlp çalışmasın diye bekler; süren eski sorgunun yanıtı yok sayılır.
  void _updateQualityProbe() {
    final text = _url.text.trim();
    final uri = Uri.tryParse(text);
    final wanted =
        _mediaMode &&
        _format == MediaFormat.mp4 &&
        !_wholePlaylist &&
        uri != null &&
        (uri.isScheme('http') || uri.isScheme('https')) &&
        uri.host.isNotEmpty;
    if (wanted && text == _probedUrl) return;
    _probeDelay?.cancel();
    _probeToken++;
    _loadingQualities = wanted;
    if (text != _probedUrl) {
      _probedUrl = null;
      _qualities = const [];
      _qualityNote = null;
      _maxHeight = _preferredHeight;
    }
    if (!wanted) return;
    final token = _probeToken;
    _probeDelay = Timer(
      const Duration(milliseconds: 600),
      () => unawaited(_probeQualities(uri, text, token)),
    );
  }

  Future<void> _probeQualities(Uri uri, String text, int token) async {
    List<MediaQuality> qualities = const [];
    String? note;
    try {
      final info = await context.read<AppController>().probeVideo(uri);
      if (!info.isPlaylist) qualities = info.qualities;
      if (qualities.isEmpty) {
        note = 'Bu adres kalite bilgisi vermedi; seçim üst sınır olarak uygulanır.';
      }
    } on DownloadException catch (e) {
      note = e.message;
    }
    if (!mounted || token != _probeToken) return;
    setState(() {
      _loadingQualities = false;
      _probedUrl = text;
      _qualities = qualities;
      _qualityNote = note;
      if (qualities.isNotEmpty) _maxHeight = _closestQuality(qualities);
    });
  }

  /// Tercihi aşmayan en yüksek kalite; hepsi aşıyorsa en düşüğü.
  int? _closestQuality(List<MediaQuality> qualities) {
    final preferred = _preferredHeight;
    if (preferred == null) return null;
    for (final quality in qualities) {
      if (quality.nominalHeight <= preferred) return quality.height;
    }
    return qualities.last.height;
  }

  String _qualityLabel(MediaQuality quality) {
    final size = quality.estimatedBytes;
    return size == null
        ? quality.label
        : '${quality.label}, yaklaşık ${formatBytes(size)}';
  }

  List<DropdownMenuItem<int?>> _qualityItems() {
    if (_qualities.isEmpty) {
      final heights = {1080, 720, 480, ?_maxHeight}.toList()
        ..sort((a, b) => b.compareTo(a));
      return [
        const DropdownMenuItem(child: Text('En iyi')),
        for (final height in heights)
          DropdownMenuItem(value: height, child: Text('${height}p')),
      ];
    }
    return [
      DropdownMenuItem(
        child: Text('En iyi (${_qualityLabel(_qualities.first)})'),
      ),
      for (final quality in _qualities)
        DropdownMenuItem(
          value: quality.height,
          child: Text(_qualityLabel(quality)),
        ),
    ];
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
    _probeDelay?.cancel();
    _pageCheckDelay?.cancel();
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
        s.mediaMaxHeight = _preferredHeight;
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
          onChanged: (value) => setState(() {
            _format = value!;
            _updateQualityProbe();
          }),
        ),
        if (_format == MediaFormat.mp4) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int?>(
            // initialValue yalnızca ilk kurulumda okunur; liste değişince yeniden kurulur.
            key: ValueKey(_qualities.map((q) => q.height).join(',')),
            initialValue: _maxHeight,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Kalite',
              helperText: _loadingQualities
                  ? 'Kaliteler okunuyor…'
                  : _qualityNote,
              helperMaxLines: 3,
            ),
            items: _qualityItems(),
            onChanged: (value) => setState(() {
              _maxHeight = value;
              // Kısa kenar değil bilinen ad: 804 seçimi sonraki videoda 720p'ye düşmesin.
              _preferredHeight =
                  _qualities
                      .where((q) => q.height == value)
                      .firstOrNull
                      ?.nominalHeight ??
                  value;
            }),
          ),
        ],
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Oynatma listesinin tamamı'),
          subtitle: const Text('Her video ayrı indirme olarak eklenir.'),
          value: _wholePlaylist,
          onChanged: (value) => setState(() {
            _wholePlaylist = value;
            _updateQualityProbe();
          }),
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
                    onSelectionChanged: (value) => setState(() {
                      _mediaMode = value.single;
                      _modeChosen = true;
                      _updateQualityProbe();
                      _updatePageCheck();
                    }),
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
