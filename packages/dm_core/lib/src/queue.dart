import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'downloader.dart';
import 'exceptions.dart';
import 'file_ops.dart';
import 'media.dart';
import 'metadata_store.dart';
import 'models.dart';
import 'torrent_worker.dart';

/// İndirme kuyruğu: aynı anda en fazla [maxConcurrent] görev çalıştırır ve
/// isteğe bağlı olarak listeyi diske yazar (uygulama yeniden açılınca geri yükler).
class DownloadQueue {
  DownloadQueue({
    int maxConcurrent = 3,
    this.persistPath,
    DownloadTuning tuning = const DownloadTuning(),
  })  : _tuning = tuning,
        _maxConcurrent = maxConcurrent < 1 ? 1 : maxConcurrent;

  final String? persistPath;
  DownloadTuning _tuning;
  DownloadTuning get tuning => _tuning;

  /// Yeni görevlerde hemen, çalışan görevlerde yeniden başlatınca geçerli olur.
  set tuning(DownloadTuning value) {
    _tuning = value;
    for (final task in _tasks) {
      task.tuning = value;
    }
  }

  final List<DownloadTask> _tasks = [];
  final Map<String, StreamSubscription<DownloadProgress>> _subscriptions = {};
  final StreamController<void> _changes = StreamController.broadcast();
  Timer? _persistDebounce;
  Future<void> _persistChain = Future.value();
  int _maxConcurrent;
  bool _disposed = false;
  final Set<String> _resumeOnRestore = {};

  /// Liste veya bir görevin durumu değişince tetiklenir.
  Stream<void> get changes => _changes.stream;
  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  int get maxConcurrent => _maxConcurrent;

  int get activeCount => _tasks.where((t) => t.state.isActive).length;

  set maxConcurrent(int value) {
    _maxConcurrent = value < 1 ? 1 : value;
    _pump();
  }

  /// Yeni indirme ekler; sıra gelince otomatik başlar.
  DownloadTask add(DownloadRequest request) {
    final task = DownloadTask(request, tuning: tuning);
    _attach(task);
    _pump();
    _notify();
    return task;
  }

  Future<void> pause(DownloadTask task) async {
    await task.pause();
    _pump();
  }

  /// Duraklatılmış veya başarısız görevi yeniden sıraya alır.
  void resume(DownloadTask task) {
    if (task.state == DownloadState.paused ||
        task.state == DownloadState.failed) {
      task.markQueued();
      _pump();
    }
  }

  Future<void> cancel(DownloadTask task) async {
    await task.cancel();
    _pump();
  }

  /// Görevi listeden çıkarır. Bitmemişse önce iptal edilir (geçici dosyalar silinir);
  /// tamamlanmış dosya yalnızca [deleteFile] ile silinir.
  Future<void> remove(DownloadTask task, {bool deleteFile = false}) async {
    if (!task.state.isTerminal) await task.cancel();
    if (deleteFile && task.state == DownloadState.completed) {
      final path = task.current.filePath;
      if (path != null) {
        try {
          if (await Directory(path).exists()) {
            await deleteTorrentFolder(task.request.directory, path);
          } else {
            final file = File(path);
            if (await file.exists()) await retryFileOperation(file.delete);
          }
        } on FileSystemException catch (e) {
          throw wrapFileSystemError('Dosya silinemedi: $path', e);
        }
      }
    }
    _tasks.remove(task);
    await _subscriptions.remove(task.id)?.cancel();
    await task.dispose();
    _notify();
    _pump();
  }

  Future<void> pauseAll() async {
    await Future.wait([
      for (final task in _tasks)
        if (task.state.isActive || task.state == DownloadState.queued)
          task.pause(),
    ]);
  }

  void resumeAll() {
    for (final task in _tasks) {
      if (task.state == DownloadState.paused) task.markQueued();
    }
    _pump();
  }

  /// Kayıtlı listeyi yükler. Kapanırken çalışmakta olanlar sıraya alınır
  /// (çökme sonrası kurtarma); kullanıcının duraklattıkları duraklatılmış kalır.
  Future<void> restore() async {
    final path = persistPath;
    if (path == null) return;
    final file = File(path);
    if (!await file.exists()) return;
    final List<dynamic> records;
    try {
      records = jsonDecode(await file.readAsString()) as List<dynamic>;
    } on FormatException catch (e) {
      throw MetadataCorruptException('Kuyruk kaydı bozuk: $path', cause: e);
    } on TypeError catch (e) {
      throw MetadataCorruptException('Kuyruk kaydı bozuk: $path', cause: e);
    } on FileSystemException catch (e) {
      throw wrapFileSystemError('Kuyruk kaydı okunamadı: $path', e);
    }
    for (final record in records) {
      final task = await _restoreTask(record as Map<String, dynamic>);
      if (task != null) _attach(task);
    }
    _notify();
    _pump();
  }

  Future<DownloadTask?> _restoreTask(Map<String, dynamic> json) async {
    final Uri url;
    final DownloadState saved;
    try {
      url = Uri.parse(json['url'] as String);
      saved = DownloadState.values.byName(json['state'] as String);
    } on Object {
      return null; // Tek bir bozuk kayıt tüm listeyi götürmesin.
    }
    final targetPath = json['targetPath'] as String?;
    var total = json['totalBytes'] as int?;
    var downloaded = json['downloadedBytes'] as int? ?? 0;

    if (targetPath != null && !saved.isTerminal) {
      try {
        final meta = await MetadataStore(targetPath).load();
        if (meta != null) {
          total = meta.size;
          downloaded = meta.downloadedBytes;
        }
      } on MetadataCorruptException {
        downloaded = 0; // Devam denemesi baştan başlayacak.
      }
    }

    final DownloadState restored = switch (saved) {
      DownloadState.probing ||
      DownloadState.downloading ||
      DownloadState.verifying ||
      DownloadState.converting ||
      DownloadState.queued =>
        DownloadState.queued,
      _ => saved,
    };

    final errorMessage = json['error'] as String?;
    return DownloadTask(
      DownloadRequest(
        url: url,
        directory: json['directory'] as String,
        fileName: json['fileName'] as String?,
        segments: json['segments'] as int? ?? defaultSegments,
        headers: (json['headers'] as Map<String, dynamic>? ?? const {})
            .map((k, v) => MapEntry(k, v as String)),
        expectedSha256: json['expectedSha256'] as String?,
        computeSha256: json['computeSha256'] as bool? ?? false,
        media: json['media'] is Map<String, dynamic>
            ? MediaOptions.fromJson(json['media'] as Map<String, dynamic>)
            : null,
      ),
      tuning: tuning,
      id: json['id'] as String?,
      targetPath: targetPath,
      initial: DownloadProgress(
        state: restored,
        totalBytes: total,
        downloadedBytes: downloaded,
        fileName: json['displayName'] as String?,
        filePath: targetPath,
        sha256: json['sha256'] as String?,
        error: errorMessage == null
            ? null
            : UnexpectedDownloadException(errorMessage),
      ),
    );
  }

  /// Bekleyen kayıtları diske yazar; kapanmadan önce çağrılmalıdır.
  Future<void> flush() async {
    _persistDebounce?.cancel();
    _persistDebounce = null;
    await _persistNow();
  }

  /// Görevleri güvenle durdurur. Çalışan veya sırada olanlar bir sonraki
  /// [restore] çağrısında kaldığı yerden devam eder.
  Future<void> dispose() async {
    _disposed = true;
    _resumeOnRestore
      ..clear()
      ..addAll(_tasks
          .where((t) => t.state.isActive || t.state == DownloadState.queued)
          .map((t) => t.id));
    await pauseAll();
    await flush();
    for (final subscription in _subscriptions.values) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    await _changes.close();
  }

  void _attach(DownloadTask task) {
    _tasks.add(task);
    var lastState = task.state;
    _subscriptions[task.id] = task.progress.listen((progress) {
      _notify();
      if (progress.state != lastState) {
        lastState = progress.state;
        // Son durum yazılmadan kapanırsa çalışan görev kurtarılır, tamamlanan
        // görev ise yeniden başlatılmaya çalışılırdı; bu yüzden hemen yaz.
        _schedulePersist(immediate: true);
        _pump();
      }
    });
    _schedulePersist();
  }

  void _pump() {
    if (_disposed) return;
    var running = _tasks.where((t) => t.state.isActive).length;
    for (final task in _tasks) {
      if (running >= _maxConcurrent) break;
      if (task.state == DownloadState.queued) {
        task.start();
        running++;
      }
    }
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
    _schedulePersist();
  }

  void _schedulePersist({bool immediate = false}) {
    if (persistPath == null) return;
    if (immediate) {
      _persistDebounce?.cancel();
      _persistDebounce = null;
      unawaited(_persistNow());
      return;
    }
    _persistDebounce ??= Timer(const Duration(seconds: 2), () {
      _persistDebounce = null;
      unawaited(_persistNow());
    });
  }

  Future<void> _persistNow() {
    final path = persistPath;
    if (path == null) return Future.value();
    // Yazımlar sıralanır, böylece eski anlık görüntü yenisinin üzerine binmez.
    final snapshot = jsonEncode(_tasks.map(_toRecord).toList());
    return _persistChain = _persistChain.then((_) async {
      try {
        final tmp = File('$path.tmp');
        await tmp.parent.create(recursive: true);
        await tmp.writeAsString(snapshot, flush: true);
        await retryFileOperation(() => tmp.rename(path));
      } on FileSystemException {
        // Kayıt yazılamaması indirmeyi durdurmamalı; sonraki değişimde denenir.
      }
    });
  }

  Map<String, dynamic> _toRecord(DownloadTask task) {
    final request = task.request;
    final progress = task.current;
    return {
      'id': task.id,
      'url': request.url.toString(),
      'directory': request.directory,
      'fileName': request.fileName,
      'segments': request.segments,
      'headers': stripSensitiveHeaders(request.headers),
      'expectedSha256': request.expectedSha256,
      'computeSha256': request.computeSha256,
      'media': task.media?.toJson(),
      'state': _resumeOnRestore.contains(task.id)
          ? DownloadState.queued.name
          : progress.state.name,
      'targetPath': task.targetPath,
      'displayName': progress.fileName,
      'totalBytes': progress.totalBytes,
      'downloadedBytes': progress.downloadedBytes,
      'sha256': progress.sha256,
      'error': progress.error?.message,
    };
  }
}
