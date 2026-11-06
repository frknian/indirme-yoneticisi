import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'file_name.dart';
import 'file_ops.dart';
import 'hash_verify.dart';
import 'media.dart';
import 'metadata_store.dart';
import 'models.dart';
import 'probe.dart';
import 'retry.dart';
import 'segment.dart';
import 'segment_worker.dart';
import 'speed_meter.dart';
import 'torrent_worker.dart';

enum _StopMode { pause, cancel }

/// Çalışma döngüsünü durdurma isteği (pause/cancel).
class _StopSignal implements Exception {
  const _StopSignal();
}

/// Segmentler bittikten sonra ne yapılacağı.
sealed class _RunOutcome {
  const _RunOutcome();
}

final class _Finished extends _RunOutcome {
  const _Finished();
}

final class _Stopped extends _RunOutcome {
  const _Stopped();
}

final class _RemoteChanged extends _RunOutcome {
  const _RemoteChanged(this.reason);
  final String reason;
}

final class _RangeIgnored extends _RunOutcome {
  const _RangeIgnored(this.reason);
  final String reason;
}

/// Tek bir indirmeyi yöneten denetleyici.
///
/// Çalışma sırası: yokla, metadata'yı doğrula veya yeni plan yap, her parça için
/// isolate başlat, bitince özet kontrol et ve `.part` dosyasını yeniden adlandır.
class DownloadTask {
  DownloadTask(
    this.request, {
    this.tuning = const DownloadTuning(),
    String? id,
    String? targetPath,
    DownloadProgress? initial,
  })  : id = id ?? _newId(),
        _targetPath = targetPath,
        _progress = initial ??
            DownloadProgress(
              state: DownloadState.queued,
              fileName: request.fileName,
            );

  final String id;
  final DownloadRequest request;

  /// Değişiklik bir sonraki başlatmada geçerli olur.
  DownloadTuning tuning;

  final StreamController<DownloadProgress> _controller =
      StreamController.broadcast();
  DownloadProgress _progress;

  String? _targetPath;
  DownloadMetadata? _meta;
  MetadataStore? _store;
  Future<void>? _running;
  _StopMode? _stopMode;
  Completer<void> _stopSignal = Completer();
  final SpeedMeter _meter = SpeedMeter();
  int _restarts = 0;

  /// İlerleme ve durum akışı; UI çekirdeğe yalnızca bununla bağlanır.
  Stream<DownloadProgress> get progress => _controller.stream;
  DownloadProgress get current => _progress;
  DownloadState get state => _progress.state;

  /// İndirme hedefi; yoklamadan önce null olabilir.
  String? get targetPath => _targetPath;

  /// Görevi kuyruk bekleyişine alır (duraklatılmış/başarısızdan devam için).
  void markQueued() {
    if (_running != null || state.isTerminal) return;
    _emit(_progress.copyWith(state: DownloadState.queued, clearError: true));
  }

  /// İndirmeyi başlatır veya devam ettirir. Zaten çalışıyorsa bir şey yapmaz.
  void start() {
    if (_running != null || state.isTerminal) return;
    _stopMode = null;
    _stopSignal = Completer();
    _running = _run().whenComplete(() => _running = null);
  }

  /// Başlatır ve indirme bitene/duraklayana/başarısız olana kadar bekler.
  Future<DownloadProgress> run() async {
    start();
    await _running;
    return _progress;
  }

  /// Çalışan iş biterken tamamlanır.
  Future<void> get settled => _running ?? Future.value();

  Future<void> pause() async {
    if (_running == null) {
      if (state == DownloadState.queued) {
        _emit(_progress.copyWith(state: DownloadState.paused));
      }
      return;
    }
    _requestStop(_StopMode.pause);
    await _running;
  }

  Future<void> resume() async {
    start();
  }

  /// İptal eder ve `.part` ile `.dmmeta` dosyalarını siler.
  Future<void> cancel() async {
    if (state == DownloadState.completed || state == DownloadState.canceled) {
      return;
    }
    if (_running != null) {
      _requestStop(_StopMode.cancel);
      await _running;
      return;
    }
    await _deleteArtifacts();
    _emit(_progress.copyWith(
      state: DownloadState.canceled,
      bytesPerSecond: 0,
      clearEta: true,
      activeConnections: 0,
    ));
  }

  Future<void> dispose() async {
    await _controller.close();
  }

  void _requestStop(_StopMode mode) {
    // İptal, önceki duraklatma isteğinden önceliklidir.
    if (_stopMode != _StopMode.cancel) _stopMode = mode;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
  }

  Future<void> _run() async {
    _meter.reset();
    try {
      if (request.media != null) {
        await _runMedia(request.media!);
        return;
      }
      if (isTorrentUri(request.url)) {
        await _runTorrent();
        return;
      }
      _emit(_progress.copyWith(
        state: DownloadState.probing,
        clearError: true,
        bytesPerSecond: 0,
        clearEta: true,
      ));
      var probe = await _probeWithRetry();
      // Web sayfası kaydedip "tamamlandı" demek yanıltıcı olurdu.
      if (probe.contentType == 'text/html') {
        throw const NotAFileException(
          'Bu adres dosya değil, web sayfası. Video ise Video/Ses seçeneğiyle '
          'indirin.',
        );
      }
      var meta = await _prepare(probe);

      while (true) {
        final outcome = await _runSegments(meta);
        switch (outcome) {
          case _Finished():
            await _finish(meta);
            return;
          case _Stopped():
            throw const _StopSignal();
          case _RemoteChanged(:final reason):
            meta = await _restartAfterChange(reason);
          case _RangeIgnored(:final reason):
            // 200 iki anlama gelebilir: dosya değişti veya Range desteği yok.
            // Yeniden yoklayıp doğrulayıcıya bakarak ayırt ederiz.
            probe = await _probeWithRetry();
            if (_validatorsChanged(meta, probe)) {
              meta = await _restartAfterChange(reason);
            } else {
              meta = await _freshMeta(probe, forceSingle: true);
            }
        }
      }
    } on _StopSignal {
      await _settleStop();
    } on DownloadException catch (e) {
      await _saveMetaQuietly();
      _emit(_progress.copyWith(
        state: DownloadState.failed,
        error: e,
        bytesPerSecond: 0,
        clearEta: true,
        activeConnections: 0,
      ));
    } on FileSystemException catch (e) {
      await _saveMetaQuietly();
      _emit(_progress.copyWith(
        state: DownloadState.failed,
        error: wrapFileSystemError('Dosya işlemi başarısız', e),
        bytesPerSecond: 0,
        clearEta: true,
        activeConnections: 0,
      ));
    } on Object catch (e) {
      await _saveMetaQuietly();
      _emit(_progress.copyWith(
        state: DownloadState.failed,
        error: UnexpectedDownloadException('Beklenmeyen hata', cause: e),
        bytesPerSecond: 0,
        clearEta: true,
        activeConnections: 0,
      ));
    }
  }

  /// yt-dlp'nin yarım dosyaları; görev kimliğine bağlı olduğu için devam ederken
  /// aynı klasör kullanılır, iptalde başka hiçbir dosyaya dokunmadan silinir.
  String get _mediaTempDir => p.join(request.directory, '.dm_media_$id');

  /// Devam edecek yarım dosya yoksa geçici klasör kullanıcının klasöründe kalmasın.
  Future<void> _deleteEmptyMediaTemp() async {
    final temp = Directory(_mediaTempDir);
    try {
      if (await temp.exists() && await temp.list().isEmpty) {
        await temp.delete();
      }
    } on FileSystemException {
      // Hata asıl indirme sorununu gizlemesin; klasör iptal edilince de silinir.
    }
  }

  Future<void> _runMedia(MediaOptions options) async {
    _emit(_progress.copyWith(
      state: DownloadState.probing,
      isMedia: true,
      resumable: true,
      clearError: true,
      bytesPerSecond: 0,
      clearEta: true,
    ));
    rejectDrmPlatform(request.url);
    final tools = locateMediaTools(
      ytDlpPath: tuning.ytDlpPath,
      ffmpegPath: tuning.ffmpegPath,
    );
    requireMediaTools(tools);
    await Directory(request.directory).create(recursive: true);
    await Directory(_mediaTempDir).create(recursive: true);

    final Process process;
    try {
      process = await Process.start(
        tools.ytDlp!,
        buildMediaDownloadArgs(
          url: request.url,
          options: options,
          homeDir: request.directory,
          tempDir: _mediaTempDir,
          ffmpeg: tools.ffmpeg,
          proxy: tuning.proxy,
          maxBytesPerSecond: tuning.maxBytesPerSecond,
          connectionTimeoutSeconds: tuning.connectionTimeout.inSeconds,
          retries: tuning.retry.maxAttempts,
        ),
        environment: mediaProcessEnvironment,
      );
    } on ProcessException catch (e) {
      throw MediaToolMissingException('yt-dlp çalıştırılamadı: ${e.message}');
    }

    unawaited(_stopSignal.future.then((_) => stopMediaProcess(process)));

    // Video ve ses ayrı akış olarak iner: biten akışlar toplama eklenir.
    var finishedBytes = 0;
    var currentBytes = 0;
    var currentTotal = 0;
    String? path;
    final stdoutDone = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .forEach((line) {
      switch (parseMediaLine(line)) {
        case MediaTitleEvent(:final title):
          _emit(_progress.copyWith(fileName: title));
        case MediaFileEvent(path: final file):
          path = file;
        case MediaConvertingEvent():
          _emit(_progress.copyWith(
            state: DownloadState.converting,
            bytesPerSecond: 0,
            clearEta: true,
          ));
        case final MediaProgressEvent event:
          if (event.finished) {
            finishedBytes += event.total ?? event.downloaded ?? currentBytes;
            currentBytes = 0;
            currentTotal = 0;
          } else {
            currentBytes = event.downloaded ?? currentBytes;
            currentTotal = event.total ?? currentTotal;
          }
          final total = finishedBytes + currentTotal;
          _emit(_progress.copyWith(
            state: DownloadState.downloading,
            downloadedBytes: finishedBytes + currentBytes,
            totalBytes: total > 0 ? total : null,
            bytesPerSecond: event.bytesPerSecond ?? 0,
            eta: event.etaSeconds == null
                ? null
                : Duration(seconds: event.etaSeconds!),
            clearEta: event.etaSeconds == null,
            activeConnections: 1,
          ));
        case null:
          break;
      }
    });
    final stderrBuffer = StringBuffer();
    final stderrDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(stderrBuffer.write);
    final exitCode = await process.exitCode;
    await Future.wait([stdoutDone, stderrDone]);

    if (_stopSignal.isCompleted) throw const _StopSignal();
    if (exitCode != 0) {
      await _deleteEmptyMediaTemp();
      throw classifyMediaError(stderrBuffer.toString(), exitCode);
    }
    final file = path;
    if (file == null) {
      throw const MediaDownloadException('yt-dlp dosya yolunu bildirmedi');
    }
    try {
      await deleteTorrentFolder(request.directory, _mediaTempDir);
    } on DownloadException {
      // Boş kalan geçici klasör indirilen dosyayı etkilemez.
    }
    final size = await File(file).length();
    _targetPath = file;
    _emit(_progress.copyWith(
      state: DownloadState.completed,
      totalBytes: size,
      downloadedBytes: size,
      bytesPerSecond: 0,
      clearEta: true,
      activeConnections: 0,
      fileName: p.basename(file),
      filePath: file,
      clearError: true,
    ));
  }

  /// Torrent motorunu kendi isolate'ında çalıştırır ve mesajlarını akışa çevirir.
  Future<void> _runTorrent() async {
    _emit(_progress.copyWith(
      state: DownloadState.probing,
      isTorrent: true,
      resumable: true,
      clearError: true,
      bytesPerSecond: 0,
      clearEta: true,
    ));
    final port = ReceivePort();
    final done = Completer<void>();
    SendPort? control;
    Isolate? isolate;
    var settled = false;
    Object? failure;
    var last = _progress.downloadedBytes;

    void requestStop() => control?.send(true);
    unawaited(_stopSignal.future.then((_) => requestStop()));

    port.listen((message) {
      switch (message) {
        case TorrentReady(:final controlPort):
          control = controlPort;
          if (_stopSignal.isCompleted) requestStop();
        case TorrentInfo(:final name, :final totalBytes, :final folder):
          _targetPath = folder;
          _emit(_progress.copyWith(
            fileName: name,
            filePath: folder,
            totalBytes: totalBytes,
          ));
        case TorrentProgress():
          _meter.add(message.downloadedBytes - last);
          last = message.downloadedBytes;
          final total = _progress.totalBytes;
          _emit(_progress.copyWith(
            state: DownloadState.downloading,
            downloadedBytes: message.downloadedBytes,
            bytesPerSecond: message.bytesPerSecond,
            uploadBytesPerSecond: message.uploadBytesPerSecond,
            peers: message.peers,
            seeds: message.seeds,
            activeConnections: message.peers,
            eta: _meter.eta(total == null ? null : total - last),
            clearEta: total == null,
          ));
        case TorrentDone(:final path, :final totalBytes):
          settled = true;
          _targetPath = path;
          _emit(_progress.copyWith(
            state: DownloadState.completed,
            totalBytes: totalBytes,
            downloadedBytes: totalBytes,
            bytesPerSecond: 0,
            uploadBytesPerSecond: 0,
            clearEta: true,
            activeConnections: 0,
            peers: 0,
            seeds: 0,
            fileName: p.basename(path),
            filePath: path,
            clearError: true,
          ));
        case TorrentStopped():
          settled = true;
        case TorrentFailed(:final error):
          settled = true;
          failure = error;
        case List<dynamic>():
          // Motorda yakalanmamış hata; ardından onExit (null) gelir.
          settled = true;
          failure = NetworkException('Torrent motoru durdu: ${message.first}');
        case null:
          if (!done.isCompleted) done.complete();
      }
    });

    try {
      isolate = await Isolate.spawn(
        torrentWorkerMain,
        TorrentWorkerConfig(
          mainPort: port.sendPort,
          source: request.url.toString(),
          directory: request.directory,
          targetPath: _targetPath,
          settings: tuning.torrent,
          proxy: tuning.proxy,
          connectionTimeout: tuning.connectionTimeout,
          progressInterval: tuning.progressInterval,
        ),
        onExit: port.sendPort,
        onError: port.sendPort,
        debugName: 'dm-torrent',
      );
      // Motor durmazsa isolate öldürülür; ilerleme kaydı motorun durum dosyasındadır.
      unawaited(_stopSignal.future.then((_) async {
        await Future<void>.delayed(const Duration(seconds: 10));
        isolate?.kill(priority: Isolate.immediate);
      }));
      await done.future;
    } finally {
      port.close();
    }

    if (_stopSignal.isCompleted && state != DownloadState.completed) {
      throw const _StopSignal();
    }
    if (failure != null) throw failure!;
    if (!settled) {
      throw const NetworkException('Torrent motoru beklenmedik şekilde durdu');
    }
  }

  Future<void> _settleStop() async {
    if (_stopMode == _StopMode.cancel) {
      await _deleteArtifacts();
      _emit(_progress.copyWith(
        state: DownloadState.canceled,
        bytesPerSecond: 0,
        clearEta: true,
        activeConnections: 0,
      ));
    } else {
      await _saveMetaQuietly();
      _emit(_progress.copyWith(
        state: DownloadState.paused,
        downloadedBytes: _meta?.downloadedBytes,
        bytesPerSecond: 0,
        clearEta: true,
        activeConnections: 0,
      ));
    }
  }

  Future<void> _saveMetaQuietly() async {
    final meta = _meta;
    final store = _store;
    if (meta == null || store == null) return;
    try {
      await store.save(meta);
    } on DownloadException {
      // Asıl hata zaten raporlanıyor; eski metadata hâlâ geçerli bir kayıt.
    }
  }

  Future<void> _deleteArtifacts() async {
    if (request.media != null) {
      try {
        await deleteTorrentFolder(request.directory, _mediaTempDir);
      } on DownloadException catch (e) {
        _emit(_progress.copyWith(error: e));
      }
      return;
    }
    final target = _targetPath;
    if (target == null) return;
    if (isTorrentUri(request.url)) {
      try {
        await deleteTorrentFolder(request.directory, target);
      } on DownloadException catch (e) {
        _emit(_progress.copyWith(error: e));
      }
      return;
    }
    try {
      await MetadataStore(target).deleteAll();
    } on DownloadException catch (e) {
      _emit(_progress.copyWith(error: e));
    }
    _meta = null;
  }

  /// [future] biterse sonucunu döndürür; durdurma istenirse [_StopSignal] atar.
  Future<T> _orStop<T>(Future<T> future) async {
    if (_stopSignal.isCompleted) throw const _StopSignal();
    final stop = _stopSignal.future.then<T>((_) => throw const _StopSignal());
    return Future.any([future, stop]);
  }

  Future<ProbeResult> _probeWithRetry() async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await _orStop(probeUrl(
          request.url,
          headers: request.headers,
          timeout: tuning.connectionTimeout,
          userAgent: tuning.userAgent,
          proxy: tuning.proxy,
        ));
      } on DownloadException catch (e) {
        if (!isTransientError(e)) rethrow;
        if (attempt >= tuning.retry.maxAttempts) {
          throw RetriesExhaustedException(attempt, e);
        }
        final retryAfter = e is HttpStatusException ? e.retryAfter : null;
        await _orStop(Future<void>.delayed(
          tuning.retry.delayFor(attempt, retryAfter: retryAfter),
        ));
      }
    }
  }

  /// Hedef yolu belirler, varsa metadata'yı doğrular veya yeni plan yapar.
  Future<DownloadMetadata> _prepare(ProbeResult probe) async {
    final dir = Directory(request.directory);
    await dir.create(recursive: true);

    final name = request.fileName != null
        ? sanitizeFileName(request.fileName!)
        : probe.fileName;
    final initialPath = p.join(request.directory, name);

    if (_targetPath == null) {
      final existing = await _loadMetaOrNull(initialPath);
      _targetPath = existing != null && existing.url == request.url.toString()
          ? initialPath
          : await _uniquePath(initialPath);
    }
    final target = _targetPath!;
    _store = MetadataStore(target);
    _emit(_progress.copyWith(
      fileName: p.basename(target),
      filePath: target,
    ));

    final existing = await _loadMetaOrNull(target);
    if (existing == null) return _freshMeta(probe);

    final part = File(partPathFor(target));
    final partOk = await part.exists() &&
        (existing.size == null || await part.length() == existing.size);
    if (!partOk) return _freshMeta(probe);

    if (_validatorsChanged(existing, probe)) {
      _restarts++;
      if (_restarts > tuning.maxRemoteRestarts) {
        throw const RemoteFileChangedException(
          'Sunucudaki dosya sürekli değişiyor',
        );
      }
      return _freshMeta(probe);
    }

    // Akışlı (Range'siz) indirmeye ortadan devam edilemez.
    if (!existing.acceptsRanges) return _freshMeta(probe);

    existing.finalUrl = probe.finalUri.toString();
    _adopt(existing);
    return existing;
  }

  Future<DownloadMetadata?> _loadMetaOrNull(String target) async {
    final store = MetadataStore(target);
    try {
      return await store.load();
    } on MetadataCorruptException {
      await store.deleteAll();
      return null;
    }
  }

  /// ETag ve Last-Modified karşılaştırması. Sunucu birini göndermiyorsa o
  /// doğrulayıcı dikkate alınmaz; boyut her durumda karşılaştırılır.
  bool _validatorsChanged(DownloadMetadata meta, ProbeResult probe) {
    if (meta.size != null && probe.size != null && meta.size != probe.size) {
      return true;
    }
    if (meta.etag != null && probe.etag != null && meta.etag != probe.etag) {
      return true;
    }
    if (meta.lastModified != null &&
        probe.lastModified != null &&
        meta.lastModified != probe.lastModified) {
      return true;
    }
    return false;
  }

  Future<DownloadMetadata> _restartAfterChange(String reason) async {
    _restarts++;
    if (_restarts > tuning.maxRemoteRestarts) {
      throw RemoteFileChangedException(
        'Sunucudaki dosya sürekli değişiyor: $reason',
      );
    }
    return _freshMeta(await _probeWithRetry());
  }

  /// Eski parçaları siler ve baştan plan yapar.
  Future<DownloadMetadata> _freshMeta(
    ProbeResult probe, {
    bool forceSingle = false,
  }) async {
    final target = _targetPath!;
    await MetadataStore(target).deleteAll();

    final size = (probe.size ?? 0) > 0 ? probe.size : null;
    final useRanges = probe.supportsSegments && !forceSingle;
    final segments = useRanges
        ? planSegments(
            size!,
            request.segments,
            minSegmentSize: tuning.minSegmentSize,
          )
        : [
            Segment(
              index: 0,
              start: 0,
              end: size == null ? Segment.unknownEnd : size - 1,
            ),
          ];

    final part = File(partPathFor(target));
    final raf = await part.open(mode: FileMode.write);
    try {
      if (useRanges) await raf.truncate(size!);
    } finally {
      await raf.close();
    }

    final meta = DownloadMetadata(
      url: request.url.toString(),
      finalUrl: probe.finalUri.toString(),
      targetPath: target,
      size: size,
      acceptsRanges: useRanges,
      etag: probe.etag,
      lastModified: probe.lastModified,
      segments: segments,
    );
    _adopt(meta);
    await _store!.save(meta);
    return meta;
  }

  void _adopt(DownloadMetadata meta) {
    _meta = meta;
    _store = MetadataStore(meta.targetPath);
    _emit(_progress.copyWith(
      totalBytes: meta.size,
      downloadedBytes: meta.downloadedBytes,
      segments: _snapshot(meta.segments, null),
      resumable: meta.acceptsRanges,
      restarts: _restarts,
    ));
  }

  List<SegmentProgress> _snapshot(
          List<Segment> segments, Map<int, int>? live) =>
      [
        for (final s in segments)
          SegmentProgress(
            index: s.index,
            start: s.start,
            end: s.end,
            downloaded: live?[s.index] ?? s.downloaded,
          ),
      ];

  Future<_RunOutcome> _runSegments(DownloadMetadata meta) async {
    final scheduler = _SegmentScheduler(
      meta: meta,
      request: request,
      tuning: tuning,
      onTick: (live, active, deltaBytes) {
        _meter.add(deltaBytes);
        final downloaded = live.values.fold<int>(0, (a, b) => a + b);
        final remaining = meta.size == null ? null : meta.size! - downloaded;
        _emit(_progress.copyWith(
          state: DownloadState.downloading,
          downloadedBytes: downloaded,
          bytesPerSecond: _meter.bytesPerSecond,
          eta: _meter.eta(remaining),
          clearEta: remaining == null,
          segments: _snapshot(meta.segments, live),
          activeConnections: active,
        ));
      },
      save: () => _store!.save(meta),
    );
    return scheduler.run(_stopSignal.future);
  }

  Future<void> _finish(DownloadMetadata meta) async {
    final target = _targetPath!;
    final partPath = partPathFor(target);

    // Boyutu başta bilinmeyen akışlarda gerçek boyut şimdi belli olur.
    final actualSize = await File(partPath).length();
    if (meta.size != null && actualSize != meta.size) {
      await _store!.deleteAll();
      throw DiskException(
        'Dosya boyutu beklenmedik: $actualSize, beklenen ${meta.size}',
      );
    }

    String? digest;
    final expected = request.expectedSha256;
    if (expected != null || request.computeSha256) {
      _emit(_progress.copyWith(
        state: DownloadState.verifying,
        downloadedBytes: actualSize,
        bytesPerSecond: 0,
        clearEta: true,
        activeConnections: 0,
      ));
      digest = await sha256OfFile(partPath);
      if (_stopSignal.isCompleted) throw const _StopSignal();
      if (expected != null && normalizeSha256(expected) != digest) {
        // Bozuk veriyle devam edilemez; tekrar deneme baştan başlamalı.
        await _store!.deleteAll();
        _meta = null;
        throw HashMismatchException(
          expected: normalizeSha256(expected),
          actual: digest,
        );
      }
    }

    final finalPath =
        await File(target).exists() ? await _uniquePath(target) : target;
    await retryFileOperation(() => File(partPath).rename(finalPath));
    await _store!.delete();
    _targetPath = finalPath;
    _meta = null;

    _emit(_progress.copyWith(
      state: DownloadState.completed,
      totalBytes: actualSize,
      downloadedBytes: actualSize,
      bytesPerSecond: 0,
      clearEta: true,
      activeConnections: 0,
      fileName: p.basename(finalPath),
      filePath: finalPath,
      sha256: digest,
      clearError: true,
    ));
  }

  void _emit(DownloadProgress next) {
    _progress = next;
    if (!_controller.isClosed) _controller.add(next);
  }

  static int _idCounter = 0;
  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_idCounter++}';
}

/// `dosya.zip` doluysa `dosya (1).zip` gibi boş bir ad bulur.
Future<String> _uniquePath(String path) async {
  bool taken(String candidate) =>
      File(candidate).existsSync() ||
      File(partPathFor(candidate)).existsSync() ||
      File(metaPathFor(candidate)).existsSync();

  if (!taken(path)) return path;
  final dir = p.dirname(path);
  final stem = p.basenameWithoutExtension(path);
  final ext = p.extension(path);
  for (var i = 1;; i++) {
    final candidate = p.join(dir, '$stem ($i)$ext');
    if (!taken(candidate)) return candidate;
  }
}

/// Bir parçanın çalışan isolate'ı.
class _Worker {
  _Worker(this.segment);

  final Segment segment;
  final ReceivePort port = ReceivePort();
  Isolate? isolate;
  SendPort? control;
  bool settled = false;
  final Completer<void> exited = Completer();

  void requestStop() => control?.send(true);

  Future<void> stopAndWait() async {
    requestStop();
    await exited.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        // Worker takıldı: kaydedilmiş ilerleme yalnızca flush edilmiş baytları
        // içerdiğinden öldürmek güvenlidir.
        isolate?.kill(priority: Isolate.immediate);
      },
    );
    port.close();
  }
}

/// Parça isolate'larını başlatır; yeniden deneme ve bağlantı sınırını yönetir.
class _SegmentScheduler {
  _SegmentScheduler({
    required this.meta,
    required this.request,
    required this.tuning,
    required this.onTick,
    required this.save,
  })  : _limit = meta.acceptsRanges ? request.segments : 1,
        _live = {for (final s in meta.segments) s.index: s.downloaded};

  final DownloadMetadata meta;
  final DownloadRequest request;
  final DownloadTuning tuning;
  final void Function(Map<int, int> live, int active, int deltaBytes) onTick;
  final Future<void> Function() save;

  final Queue<Segment> _pending = Queue();
  final Map<int, _Worker> _active = {};
  final Set<Timer> _retryTimers = {};
  final Map<int, int> _attempts = {};
  final Map<int, int> _live;
  final Completer<_RunOutcome> _result = Completer();
  int _limit;
  int _pendingDelta = 0;
  bool _stopping = false;
  bool _saving = false;
  bool _dirty = false;

  Future<_RunOutcome> run(Future<void> stopSignal) async {
    for (final segment in meta.segments) {
      if (!segment.isComplete) _pending.add(segment);
    }
    // Boyutu bilinmeyen akış dışında hepsi tamamsa (ör. çökme son anda oldu).
    if (_pending.isEmpty) return const _Finished();

    final tick = Timer.periodic(tuning.progressInterval, (_) => _tick());
    final saver =
        Timer.periodic(tuning.metadataInterval, (_) => _saveIfDirty());
    unawaited(stopSignal.then((_) => _finishWith(const _Stopped())));
    _tick();
    _pump();

    try {
      final outcome = await _result.future;
      await _stopAll();
      await _awaitSaveThenPersist();
      if (outcome is _Finished) _tick();
      return outcome;
    } on Object {
      await _stopAll();
      await _awaitSaveThenPersist();
      rethrow;
    } finally {
      tick.cancel();
      saver.cancel();
      for (final timer in _retryTimers) {
        timer.cancel();
      }
      _retryTimers.clear();
    }
  }

  void _tick() {
    final delta = _pendingDelta;
    _pendingDelta = 0;
    onTick(_live, _active.length, delta);
  }

  void _pump() {
    while (!_stopping && _active.length < _limit && _pending.isNotEmpty) {
      unawaited(_spawn(_pending.removeFirst()));
    }
    _checkDone();
  }

  void _checkDone() {
    if (_stopping) return;
    if (_active.isEmpty && _pending.isEmpty && _retryTimers.isEmpty) {
      _finishWith(const _Finished());
    }
  }

  void _finishWith(_RunOutcome outcome) {
    if (_result.isCompleted) return;
    _stopping = true;
    _result.complete(outcome);
  }

  void _fail(DownloadException error) {
    if (_result.isCompleted) return;
    _stopping = true;
    _result.completeError(error);
  }

  /// Hız sınırını kalan parçalar arasında eşit böler.
  int _shareOfLimit() {
    final limit = tuning.maxBytesPerSecond;
    if (limit <= 0) return 0;
    final incomplete = meta.segments.where((s) => !s.isComplete).length;
    final workers = max(1, min(_limit, incomplete));
    return max(1, limit ~/ workers);
  }

  Future<void> _spawn(Segment segment) async {
    final worker = _Worker(segment);
    _active[segment.index] = worker;
    worker.port.listen((message) => _onMessage(worker, message));
    try {
      worker.isolate = await Isolate.spawn(
        segmentWorkerMain,
        WorkerConfig(
          mainPort: worker.port.sendPort,
          url: meta.finalUrl,
          partPath: partPathFor(meta.targetPath),
          segmentIndex: segment.index,
          start: segment.start,
          end: segment.end,
          alreadyDownloaded: segment.downloaded,
          useRange: meta.acceptsRanges,
          headers: request.headers,
          idleTimeout: tuning.idleTimeout,
          connectionTimeout: tuning.connectionTimeout,
          reportInterval: tuning.progressInterval,
          flushInterval: tuning.flushInterval,
          etag: meta.etag,
          lastModified: meta.lastModified,
          userAgent: tuning.userAgent,
          proxy: tuning.proxy,
          maxBytesPerSecond: _shareOfLimit(),
        ),
        onExit: worker.port.sendPort,
        onError: worker.port.sendPort,
        debugName: 'dm-segment-${segment.index}',
      );
    } on Object catch (e) {
      _active.remove(segment.index);
      worker.port.close();
      if (!worker.exited.isCompleted) worker.exited.complete();
      _fail(UnexpectedDownloadException('Isolate başlatılamadı', cause: e));
    }
  }

  void _onMessage(_Worker worker, Object? message) {
    final segment = worker.segment;
    switch (message) {
      case WorkerReady(:final controlPort):
        worker.control = controlPort;
        // Durdurma isteği worker hazır olmadan gelmiş olabilir.
        if (_stopping) worker.requestStop();
      case WorkerProgress(:final live, :final durable):
        _recordLive(segment, live);
        _recordDurable(segment, durable);
      case WorkerDone(:final downloaded):
        worker.settled = true;
        _recordLive(segment, downloaded);
        _recordDurable(segment, downloaded);
      case WorkerStopped(:final durable):
        worker.settled = true;
        _recordDurable(segment, durable);
        _live[segment.index] = durable;
      case WorkerFailed():
        worker.settled = true;
        _recordDurable(segment, message.durable);
        _live[segment.index] = segment.downloaded;
        _handleFailure(segment, message);
      case null:
        _onExit(worker);
      case List<dynamic>():
        // Worker'da yakalanmamış hata; ardından onExit (null) gelir.
        if (!worker.settled) {
          worker.settled = true;
          _handleFailure(
            segment,
            WorkerFailed(
              kind: WorkerFailureKind.network,
              message: 'Worker beklenmedik şekilde durdu: ${message.first}',
              durable: segment.downloaded,
            ),
          );
        }
    }
  }

  void _onExit(_Worker worker) {
    if (!worker.exited.isCompleted) worker.exited.complete();
    if (_active[worker.segment.index] == worker) {
      _active.remove(worker.segment.index);
    }
    worker.port.close();
    if (!worker.settled && !_stopping) {
      // Isolate mesaj bırakmadan öldü: geçici hata gibi ele al.
      _handleFailure(
        worker.segment,
        WorkerFailed(
          kind: WorkerFailureKind.network,
          message: 'Worker mesaj bırakmadan sonlandı',
          durable: worker.segment.downloaded,
        ),
      );
    }
    _pump();
  }

  void _recordLive(Segment segment, int live) {
    final previous = _live[segment.index] ?? 0;
    if (live > previous) _pendingDelta += live - previous;
    _live[segment.index] = live;
  }

  void _recordDurable(Segment segment, int durable) {
    // Bir parça başarılı veri aldıysa ardışık hata sayacı sıfırlanır.
    if (durable > segment.downloaded) _attempts.remove(segment.index);
    segment.downloaded = durable;
    _dirty = true;
  }

  void _handleFailure(Segment segment, WorkerFailed failure) {
    if (_stopping) return;
    switch (failure.kind) {
      case WorkerFailureKind.rangeIgnored:
        _finishWith(_RangeIgnored(failure.message));
        return;
      case WorkerFailureKind.remoteChanged:
        _finishWith(_RemoteChanged(failure.message));
        return;
      case WorkerFailureKind.disk:
        _fail(DiskException(failure.message));
        return;
      case WorkerFailureKind.diskFull:
        _fail(DiskFullException(failure.message));
        return;
      case WorkerFailureKind.httpStatus:
      case WorkerFailureKind.network:
        break;
    }

    final DownloadException error = failure.kind == WorkerFailureKind.httpStatus
        ? HttpStatusException(
            failure.statusCode!,
            retryAfter: failure.retryAfter,
          )
        : NetworkException(failure.message);

    if (!isTransientError(error)) {
      _fail(error);
      return;
    }

    // Sunucu yük bildiriyorsa eşzamanlı bağlantıyı azalt.
    if (failure.statusCode != null && isThrottleStatus(failure.statusCode!)) {
      _limit = max(1, _limit ~/ 2);
    }

    final attempt = (_attempts[segment.index] ?? 0) + 1;
    _attempts[segment.index] = attempt;
    if (attempt >= tuning.retry.maxAttempts) {
      _fail(RetriesExhaustedException(attempt, error));
      return;
    }

    if (!meta.acceptsRanges) {
      // Range yok: yeniden deneme dosya başından yazar.
      segment.downloaded = 0;
      _live[segment.index] = 0;
      _dirty = true;
    }

    final delay =
        tuning.retry.delayFor(attempt, retryAfter: failure.retryAfter);
    late final Timer timer;
    timer = Timer(delay, () {
      _retryTimers.remove(timer);
      if (_stopping) return;
      _pending.add(segment);
      _pump();
    });
    _retryTimers.add(timer);
  }

  Future<void> _stopAll() async {
    _stopping = true;
    final workers = _active.values.toList();
    await Future.wait(workers.map((w) => w.stopAndWait()));
    _active.clear();
  }

  void _saveIfDirty() {
    if (!_dirty || _saving) return;
    unawaited(_persist().catchError((Object e) {
      if (e is DownloadException) {
        _fail(e);
      } else {
        _fail(UnexpectedDownloadException('Metadata yazılamadı', cause: e));
      }
    }));
  }

  Future<void> _persist() async {
    _saving = true;
    _dirty = false;
    try {
      await save();
    } finally {
      _saving = false;
    }
  }

  Future<void> _awaitSaveThenPersist() async {
    while (_saving) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (_dirty) await _persist();
  }
}
