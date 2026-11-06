import 'dart:async';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'format.dart';
import 'platform_bridge.dart';
import 'settings.dart';

/// UI ile çekirdek arasındaki tek bağlantı noktası.
class AppController extends ChangeNotifier {
  AppController({
    required this.settings,
    required this.queue,
    required this.bridge,
    required this.settingsFile,
  }) {
    _subscriptions
      ..add(queue.changes.listen((_) => _onQueueChanged()))
      ..add(bridge.sharedUrls.listen(_onSharedUrl))
      ..add(bridge.pauseAllRequests.listen((_) => unawaited(pauseAll())));
  }

  static Future<AppController> create() async {
    final support = await getApplicationSupportDirectory();
    final defaultDir = await _defaultDownloadDirectory(support);
    final settingsFile = File(p.join(support.path, 'settings.json'));
    final settings = await AppSettings.load(
      settingsFile,
      defaultDirectory: defaultDir,
    );
    // Android'de seçili klasör yoktur: dosyalar önce uygulama klasörüne iner.
    if (Platform.isAndroid) settings.downloadDirectory = defaultDir;
    await settings.save(settingsFile);

    final queue = DownloadQueue(
      maxConcurrent: settings.maxConcurrent,
      tuning: settings.tuning,
      persistPath: p.join(support.path, 'queue.json'),
    );
    final controller = AppController(
      settings: settings,
      queue: queue,
      bridge: PlatformBridge(),
      settingsFile: settingsFile,
    );
    await controller._initialize();
    return controller;
  }

  static Future<String> _defaultDownloadDirectory(Directory support) async {
    if (Platform.isAndroid) {
      final external = await getExternalStorageDirectory();
      return p.join((external ?? support).path, 'downloads');
    }
    final downloads = await getDownloadsDirectory();
    return downloads?.path ?? p.join(support.path, 'downloads');
  }

  final AppSettings settings;
  final DownloadQueue queue;
  final PlatformBridge bridge;
  final File settingsFile;

  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Set<String> _publishAttempted = {};
  final StreamController<String> _incomingUrls = StreamController.broadcast();
  CaptureServer? _captureServer;
  DownloadException? _captureError;
  DownloadException? _startupError;
  String? _pendingUrl;
  String? _publishError;
  Future<void> _settingsWrite = Future.value();
  DateTime _lastForegroundUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  bool _foregroundRunning = false;
  bool _notificationAsked = false;
  bool _foregroundBlocked = false;

  static bool get isDesktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  List<DownloadTask> get tasks => queue.tasks;

  /// Yakalama sunucusu başlatılamadıysa nedeni.
  DownloadException? get captureError => _captureError;
  bool get captureRunning => _captureServer?.isRunning ?? false;

  /// Kayıtlı liste açılışta okunamadıysa nedeni.
  DownloadException? get startupError => _startupError;

  /// Sistem foreground service'e izin vermedi; indirmeler arka planda durabilir.
  bool get foregroundBlocked => _foregroundBlocked;

  /// Son MediaStore aktarım hatası; dosya uygulama klasöründe kalır.
  String? get publishError => _publishError;

  void clearPublishError() {
    _publishError = null;
    notifyListeners();
  }

  /// Paylaşımla gelen adres; UI onay penceresi açmak için dinler.
  Stream<String> get incomingUrls => _incomingUrls.stream;

  /// Abone olmadan önce gelen paylaşımı bir kez verir.
  String? takePendingUrl() {
    final url = _pendingUrl;
    _pendingUrl = null;
    return url;
  }

  Future<void> _initialize() async {
    try {
      await queue.restore();
    } on DownloadException catch (e) {
      _startupError = e;
    }
    _pendingUrl = await bridge.takePendingSharedUrl();
    if (isDesktop && settings.captureEnabled) await _startCapture();
    _onQueueChanged();
  }

  Future<void> _startCapture() async {
    await _stopCapture();
    final server = CaptureServer(
      token: settings.captureToken,
      port: settings.capturePort,
      onRequest: (request) {
        addDownload(
          request.url,
          fileName: request.fileName,
          headers: {if (request.referer != null) 'Referer': request.referer!},
        );
      },
    );
    try {
      await server.start();
      _captureServer = server;
      _captureError = null;
    } on CaptureServerException catch (e) {
      _captureError = e;
    }
    notifyListeners();
  }

  Future<void> _stopCapture() async {
    await _captureServer?.stop();
    _captureServer = null;
  }

  void _onSharedUrl(String url) {
    if (_incomingUrls.hasListener) {
      _incomingUrls.add(url);
    } else {
      _pendingUrl = url;
    }
  }

  /// Geçersiz adreste [InvalidUrlException] fırlatır.
  DownloadTask addDownload(
    Uri url, {
    String? fileName,
    String? expectedSha256,
    Map<String, String> headers = const {},
    MediaOptions? media,
  }) {
    if (!isTorrentUri(url)) validateDownloadUri(url);
    // Eklentiden gelen video sayfaları web sayfası olarak kaydedilmesin.
    media ??= isMediaSupported && isLikelyMediaUrl(url)
        ? settings.mediaOptions
        : null;
    if (!_notificationAsked) {
      _notificationAsked = true;
      unawaited(bridge.requestNotificationPermission());
    }
    return queue.add(
      DownloadRequest(
        url: url,
        directory: settings.downloadDirectory,
        fileName: fileName,
        segments: settings.segments,
        headers: headers,
        expectedSha256: expectedSha256,
        media: media,
      ),
    );
  }

  Future<void> pause(DownloadTask task) => queue.pause(task);
  void resume(DownloadTask task) => queue.resume(task);
  Future<void> cancel(DownloadTask task) => queue.cancel(task);
  Future<void> pauseAll() => queue.pauseAll();
  void resumeAll() => queue.resumeAll();

  Future<void> remove(DownloadTask task, {bool deleteFile = false}) =>
      queue.remove(task, deleteFile: deleteFile);

  Future<void> updateSettings(void Function(AppSettings) change) async {
    final beforeEnabled = settings.captureEnabled;
    final beforePort = settings.capturePort;
    final beforeToken = settings.captureToken;
    change(settings);
    queue.maxConcurrent = settings.maxConcurrent;
    queue.tuning = settings.tuning;
    await _saveSettings();
    final captureChanged =
        beforeEnabled != settings.captureEnabled ||
        beforePort != settings.capturePort ||
        beforeToken != settings.captureToken;
    if (isDesktop && captureChanged) {
      if (settings.captureEnabled) {
        await _startCapture();
      } else {
        await _stopCapture();
        _captureError = null;
      }
    }
    notifyListeners();
  }

  /// Kayıtlar sıraya alınır: aynı anda iki yazım geçici dosyada çakışır. Hata
  /// indirmeyi etkilemez, kullanıcıya bildirilir.
  Future<void> _saveSettings() {
    return _settingsWrite = _settingsWrite.then((_) async {
      try {
        await settings.save(settingsFile);
      } on FileSystemException catch (e) {
        _publishError = 'Ayarlar kaydedilemedi: ${e.message}';
        notifyListeners();
      }
    });
  }

  Future<void> regenerateCaptureToken() =>
      updateSettings((s) => s.captureToken = CaptureServer.generateToken());

  /// Masaüstünde dosyayı dosya yöneticisinde gösterir.
  Future<void> revealInFolder(String path) async {
    if (!isDesktop) return;
    final (String command, List<String> args) = Platform.isMacOS
        ? ('open', ['-R', path])
        : Platform.isWindows
        ? ('explorer', ['/select,', path])
        : ('xdg-open', [p.dirname(path)]);
    await Process.run(command, args);
  }

  void _onQueueChanged() {
    notifyListeners();
    if (Platform.isAndroid) {
      unawaited(_syncForeground());
      _publishCompleted();
    }
  }

  Future<void> _syncForeground() async {
    final active = tasks
        .where((t) => t.state.isActive || t.state == DownloadState.queued)
        .toList();
    if (active.isEmpty) {
      if (_foregroundRunning) {
        _foregroundRunning = false;
        _foregroundBlocked = false;
        await bridge.stopForeground();
      }
      return;
    }

    // Bildirim saniyede en fazla bir kez güncellenir.
    final now = DateTime.now();
    if (_foregroundRunning &&
        now.difference(_lastForegroundUpdate) < const Duration(seconds: 1)) {
      return;
    }
    _lastForegroundUpdate = now;

    final progress = active.map((t) => t.current).toList();
    final hasUnknown = progress.any((p) => p.totalBytes == null);
    final total = progress.fold<int>(0, (a, p) => a + (p.totalBytes ?? 0));
    final done = progress.fold<int>(0, (a, p) => a + p.downloadedBytes);
    final speed = progress.fold<double>(0, (a, p) => a + p.bytesPerSecond);
    final started = await bridge.updateForeground(
      title: active.length == 1
          ? (active.single.current.fileName ?? 'İndiriliyor')
          : '${active.length} indirme sürüyor',
      text: '${formatBytes(done)}  •  ${formatBytes(speed.round())}/sn',
      percent: hasUnknown || total == 0 ? null : (done * 100 ~/ total),
    );
    _foregroundRunning = started;
    if (_foregroundBlocked == started) {
      _foregroundBlocked = !started;
      notifyListeners();
    }
  }

  /// Android: biten dosyaları herkese açık İndirilenler'e taşır.
  void _publishCompleted() {
    for (final task in tasks) {
      if (task.state != DownloadState.completed) continue;
      if (!_publishAttempted.add(task.id)) continue;
      final path = task.current.filePath;
      final name = task.current.fileName;
      if (path == null || name == null) continue;
      if (Directory(path).existsSync()) {
        unawaited(_publishFolder(path));
      } else if (File(path).existsSync()) {
        unawaited(_publish(path, name));
      }
    }
  }

  /// Çok dosyalı torrentin dosyalarını tek tek aktarır, sonra klasörü siler.
  Future<void> _publishFolder(String path) async {
    final files = Directory(path)
        .listSync(recursive: true)
        .whereType<File>()
        .toList();
    for (final file in files) {
      if (!await _publish(file.path, p.basename(file.path))) return;
    }
    await Directory(path).delete(recursive: true);
    notifyListeners();
  }

  Future<bool> _publish(String path, String name) async {
    try {
      await bridge.publishToDownloads(path, name);
      notifyListeners();
      return true;
    } on PlatformException catch (e) {
      _publishError = '$name İndirilenler klasörüne aktarılamadı: ${e.message}';
      notifyListeners();
      return false;
    }
  }

  /// Oynatma listesini okur ve her videoyu ayrı indirme olarak ekler. Liste kendi
  /// klasörüne iner. Eklenen öğe sayısını döndürür.
  /// Adres dosya değil web sayfası mı? Bilinemiyorsa false: indirme yine dosya olarak başlar,
  /// sayfa çıkarsa görev kendisi videoya geçer.
  Future<bool> isWebPage(Uri url) async {
    try {
      final probe = await probeUrl(
        url,
        timeout: const Duration(seconds: 10),
        proxy: settings.proxy,
      );
      return probe.contentType == 'text/html';
    } on DownloadException {
      return false;
    }
  }

  /// Tek bir videonun bilgisini ve gerçek kalitelerini sorgular.
  Future<MediaInfo> probeVideo(Uri url) => probeMedia(
    url,
    locateMediaTools(),
    wholePlaylist: false,
    proxy: settings.proxy,
    timeout: const Duration(seconds: 60),
  );

  Future<int> addMediaPlaylist(Uri url, MediaOptions media) async {
    final info = await probeMedia(
      url,
      locateMediaTools(),
      proxy: settings.proxy,
    );
    if (!info.isPlaylist) {
      addDownload(url, media: media);
      return 1;
    }
    final folder = p.join(
      settings.downloadDirectory,
      sanitizeFileName(info.title),
    );
    for (final entry in info.entries) {
      queue.add(
        DownloadRequest(
          url: entry.url,
          directory: folder,
          fileName: null,
          segments: settings.segments,
          media: media,
        ),
      );
    }
    return info.entries.length;
  }

  /// Seçilen `.torrent` dosyasını uygulama klasörüne kopyalar: kaynak silinse veya
  /// geçici olsa da indirme uygulama yeniden açıldığında sürebilir.
  Future<Uri> importTorrentFile(String path) async {
    final folder = Directory(p.join(settingsFile.parent.path, 'torrents'));
    await folder.create(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final copy = await File(
      path,
    ).copy(p.join(folder.path, '$stamp-${sanitizeFileName(p.basename(path))}'));
    return copy.uri;
  }

  /// Uygulama kapanırken: indirmeleri güvenle durdurur, listeyi kaydeder.
  Future<void> shutdown() async {
    await _stopCapture();
    await queue.dispose();
    if (_foregroundRunning) await bridge.stopForeground();
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    unawaited(_incomingUrls.close());
    super.dispose();
  }
}
