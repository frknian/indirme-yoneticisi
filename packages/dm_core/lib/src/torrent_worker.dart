import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dtorrent_task_v2/dtorrent_task_v2.dart';
import 'package:path/path.dart' as p;

import 'exceptions.dart';
import 'file_name.dart';
import 'file_ops.dart';
import 'metadata_store.dart';
import 'models.dart';

/// `.torrent` dosyası için üst sınır; kötü niyetli sunucu belleği dolduramasın.
const int _maxTorrentFileBytes = 16 * 1024 * 1024;

class TorrentWorkerConfig {
  const TorrentWorkerConfig({
    required this.mainPort,
    required this.source,
    required this.directory,
    required this.settings,
    required this.connectionTimeout,
    required this.progressInterval,
    this.targetPath,
    this.proxy,
  });

  final SendPort mainPort;

  /// `magnet:`, `file:` veya `http(s):` adresi.
  final String source;
  final String directory;
  final String? targetPath;
  final TorrentSettings settings;
  final Duration connectionTimeout;
  final Duration progressInterval;
  final String? proxy;
}

final class TorrentReady {
  const TorrentReady(this.controlPort);
  final SendPort controlPort;
}

final class TorrentInfo {
  const TorrentInfo(this.name, this.totalBytes, this.folder);
  final String name;
  final int totalBytes;
  final String folder;
}

final class TorrentProgress {
  const TorrentProgress({
    required this.downloadedBytes,
    required this.bytesPerSecond,
    required this.uploadBytesPerSecond,
    required this.peers,
    required this.seeds,
  });
  final int downloadedBytes;
  final double bytesPerSecond;
  final double uploadBytesPerSecond;
  final int peers;
  final int seeds;
}

final class TorrentDone {
  const TorrentDone(this.path, this.totalBytes);
  final String path;
  final int totalBytes;
}

final class TorrentStopped {
  const TorrentStopped();
}

final class TorrentFailed {
  const TorrentFailed(this.error);
  final DownloadException error;
}

/// Motorun açabileceği yol, temizlenmiş klasörün dışına çıkmamalı.
void validateTorrentModel(TorrentModel model) {
  for (final file in model.files) {
    if (!isSafeTorrentPath(file.path)) {
      throw InvalidTorrentException(
          'Torrent güvensiz dosya yolu içeriyor: ${file.path}');
    }
  }
  if (model.files.isEmpty) {
    throw const InvalidTorrentException('Torrent dosya içermiyor');
  }
}

/// Bir torrent klasörünü siler; [directory] dışındaki bir yola asla dokunmaz.
Future<void> deleteTorrentFolder(String directory, String target) async {
  if (!p.isWithin(directory, target)) {
    throw DiskException('İndirme klasörü dışında silme reddedildi: $target');
  }
  try {
    final folder = Directory(target);
    if (await folder.exists()) {
      await retryFileOperation(() => folder.delete(recursive: true));
    }
  } on FileSystemException catch (e) {
    throw wrapFileSystemError('Klasör silinemedi: $target', e);
  }
}

class _Stop implements Exception {
  const _Stop();
}

/// Torrent motorunu çalıştırır; [Isolate.spawn] girişi olduğu için üst düzeydedir.
Future<void> torrentWorkerMain(TorrentWorkerConfig config) async {
  // Motor kapanırken kapalı akışa yazmak gibi eşzamansız hatalar atabiliyor. Bunlar
  // isolate'ı öldürmesin; indirme gerçekten etkilenirse bekçi motoru yeniden başlatır,
  // ilerleme de hiç gelmezse son hata kullanıcıya raporlanır.
  await runZonedGuarded(
    () => _workerBody(config),
    (error, stack) => _lastEngineError = error,
  );
}

Object? _lastEngineError;

Future<void> _workerBody(TorrentWorkerConfig config) async {
  final control = ReceivePort();
  final stop = Completer<void>();
  final controlSub = control.listen((_) {
    if (!stop.isCompleted) stop.complete();
  });
  config.mainPort.send(TorrentReady(control.sendPort));

  TorrentEngineConfig.portForwarding = config.settings.portForwarding;
  TorrentEngineConfig.listenPort = config.settings.listenPort;
  TorrentEngineConfig.maxActivePeers = config.settings.maxPeers;
  TorrentEngineConfig.dht = config.settings.dht;
  TorrentEngineConfig.allowLoopbackPeers = config.settings.allowLoopbackPeers;

  Object message = const TorrentStopped();
  try {
    final loaded = await _load(config, stop.future);
    final model = loaded.model;
    validateTorrentModel(model);

    final total = model.totalSize;
    final folder = config.targetPath != null &&
            await Directory(config.targetPath!).exists()
        ? config.targetPath!
        : await _uniqueFolder(
            p.join(config.directory, sanitizeFileName(model.name)),
          );
    await Directory(folder).create(recursive: true);
    config.mainPort.send(TorrentInfo(model.name, total, folder));

    final finished = await _download(config, loaded, folder, stop.future);
    if (finished) {
      final path = await _finalize(folder, model);
      message = TorrentDone(path, total);
    }
  } on _Stop {
    message = const TorrentStopped();
  } on DownloadException catch (e) {
    message = TorrentFailed(e);
  } on FileSystemException catch (e) {
    message = TorrentFailed(wrapFileSystemError('Torrent yazılamadı', e));
  } on FormatException catch (e) {
    message = TorrentFailed(
      InvalidTorrentException('Torrent okunamadı: ${e.message}', cause: e),
    );
  } on ArgumentError catch (e) {
    message = TorrentFailed(InvalidTorrentException('$e', cause: e));
  } on SocketException catch (e) {
    message = TorrentFailed(NetworkException('Bağlantı hatası', cause: e));
  } on Object catch (e) {
    message =
        TorrentFailed(UnexpectedDownloadException('Torrent hatası', cause: e));
  }
  await controlSub.cancel();
  control.close();
  // Motorun zamanlayıcıları isolate'ı ayakta tutabilir: mesajla birlikte kapat.
  Isolate.exit(config.mainPort, message);
}

class _Loaded {
  _Loaded(this.model, {this.magnet, this.peers = const []});
  final TorrentModel model;
  final MagnetLink? magnet;
  final List<Peer> peers;
}

Future<_Loaded> _load(TorrentWorkerConfig config, Future<void> stop) async {
  final uri = Uri.parse(config.source);
  if (uri.isScheme('magnet')) return _loadMagnet(config, stop);
  final bytes =
      uri.isScheme('file') ? await _readLocal(uri) : await _fetch(uri, config);
  return _Loaded(_parse(bytes));
}

/// Ayrıştırıcı bozuk girdide çeşitli tipler fırlatır: tek bir açık tipe çevrilir.
TorrentModel _parse(Uint8List bytes) {
  try {
    return TorrentParser.parseBytes(bytes);
  } on Object catch (e) {
    throw InvalidTorrentException('Torrent dosyası okunamadı', cause: e);
  }
}

Future<Uint8List> _readLocal(Uri uri) async {
  final file = File(uri.toFilePath());
  if (!await file.exists()) {
    throw InvalidTorrentException('Torrent dosyası bulunamadı: ${file.path}');
  }
  if (await file.length() > _maxTorrentFileBytes) {
    throw const InvalidTorrentException('Torrent dosyası çok büyük');
  }
  return file.readAsBytes();
}

Future<Uint8List> _fetch(Uri uri, TorrentWorkerConfig config) async {
  final client = HttpClient()..connectionTimeout = config.connectionTimeout;
  if (config.proxy != null) client.findProxy = (_) => 'PROXY ${config.proxy}';
  try {
    final request = await client.getUrl(uri).timeout(config.connectionTimeout);
    final response = await request.close().timeout(config.connectionTimeout);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpStatusException(response.statusCode);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(config.connectionTimeout)) {
      bytes.add(chunk);
      if (bytes.length > _maxTorrentFileBytes) {
        throw const InvalidTorrentException('Torrent dosyası çok büyük');
      }
    }
    return bytes.takeBytes();
  } on SocketException catch (e) {
    throw NetworkException('Torrent dosyası alınamadı: ${uri.host}', cause: e);
  } on HttpException catch (e) {
    throw NetworkException('Torrent dosyası alınamadı: ${e.message}', cause: e);
  } on TimeoutException catch (e) {
    throw NetworkException('Torrent dosyası zaman aşımı: ${uri.host}',
        cause: e);
  } finally {
    client.close(force: true);
  }
}

Future<_Loaded> _loadMagnet(
    TorrentWorkerConfig config, Future<void> stop) async {
  final magnet = MagnetParser.parse(config.source);
  if (magnet == null) {
    throw const InvalidTorrentException('Magnet bağlantısı geçersiz');
  }
  final downloader = MetadataDownloader.fromMagnet(config.source);
  final completer = Completer<Uint8List>();
  final listener = downloader.createListener();
  listener.on<MetaDataDownloadComplete>((event) {
    if (!completer.isCompleted) {
      completer.complete(Uint8List.fromList(event.data));
    }
  });
  try {
    unawaited(downloader.startDownload());
    final data = await Future.any<Uint8List>([
      completer.future,
      stop.then<Uint8List>((_) => throw const _Stop()),
      Future<Uint8List>.delayed(
        config.settings.metadataTimeout,
        () => throw const NetworkException(
          'Magnet bilgisi alınamadı: eş bulunamadı',
        ),
      ),
    ]);
    // Bilgi sözlüğünü `d4:info<veri>e` içine alarak ham baytları korur: özet değişmez.
    final wrapped = BytesBuilder()
      ..add('d4:info'.codeUnits)
      ..add(data)
      ..addByte(0x65);
    final model = _parse(wrapped.takeBytes());
    if (model.infoHash.toLowerCase() != magnet.infoHashString.toLowerCase()) {
      throw const InvalidTorrentException(
        'Alınan bilgi magnet özetiyle eşleşmiyor',
      );
    }
    return _Loaded(
      model,
      magnet: magnet,
      peers: downloader.activePeers.toList(),
    );
  } finally {
    unawaited(Future<void>.sync(listener.dispose));
    unawaited(downloader.stop());
  }
}

/// İndirme bitince true, durdurma istenince false döner.
Future<bool> _download(
  TorrentWorkerConfig config,
  _Loaded loaded,
  String folder,
  Future<void> stop,
) async {
  final model = loaded.model;
  var stopped = false;
  unawaited(stop.then((_) => stopped = true));
  var hints = loaded.peers;
  var restartsWithoutProgress = 0;

  while (true) {
    final task = TorrentTask.newTask(
      model,
      folder,
      false,
      loaded.magnet?.webSeeds.isNotEmpty == true
          ? loaded.magnet!.webSeeds
          : null,
    );
    final completed = Completer<void>();
    final restart = Completer<void>();
    final listener = task.createListener();
    listener.on<TaskCompleted>((_) {
      if (!completed.isCompleted) completed.complete();
    });

    await task.start();
    for (final peer in hints) {
      task.addPeer(peer.address, PeerSource.manual, type: peer.type);
    }
    hints = const [];
    final magnetTrackers = loaded.magnet?.trackers ?? const <Uri>[];
    for (final tracker in magnetTrackers) {
      task.startAnnounceUrl(tracker, model.infoHashBuffer);
    }

    final startBytes = task.downloaded ?? 0;
    var lastBytes = startBytes;
    var lastChange = DateTime.now();
    final timer = Timer.periodic(config.progressInterval, (_) {
      final downloaded = task.downloaded ?? 0;
      config.mainPort.send(TorrentProgress(
        downloadedBytes: downloaded,
        // Motor hızı bayt/ms cinsinden verir.
        bytesPerSecond: task.currentDownloadSpeed * 1000,
        uploadBytesPerSecond: task.uploadSpeed * 1000,
        peers: task.connectedPeersNumber,
        seeds: task.seederNumber,
      ));
      if (downloaded != lastBytes) {
        lastBytes = downloaded;
        lastChange = DateTime.now();
      } else if (DateTime.now().difference(lastChange) >
              config.settings.stallTimeout &&
          (task.connectedPeersNumber > 0 || _lastEngineError != null) &&
          !restart.isCompleted) {
        // Eş var ama veri gelmiyor (son parçalarda görülen takılma) veya motor hata verdi.
        restart.complete();
      }
    });

    await Future.any<void>([completed.future, restart.future, stop]);
    timer.cancel();
    unawaited(Future<void>.sync(listener.dispose));
    final done = completed.isCompleted;
    try {
      await task.stop().timeout(const Duration(seconds: 5));
      await task.dispose().timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // Durum dosyası parça tamamlandıkça yazıldığı için ilerleme kaybolmaz.
    }
    if (done) return true;
    if (stopped) return false;
    if (_lastEngineError != null && (task.downloaded ?? 0) == startBytes) {
      restartsWithoutProgress++;
      if (restartsWithoutProgress >= 3) {
        throw UnexpectedDownloadException(
          'Torrent motoru ilerleyemiyor',
          cause: _lastEngineError,
        );
      }
    } else {
      restartsWithoutProgress = 0;
    }
    _lastEngineError = null;
  }
}

/// İçeriği çalışma klasöründen çıkarıp son adına taşır ve çalışma klasörünü siler.
///
/// Motor dosyaları `<klasör>/<torrent adı>...` altına yazar. Çalışma klasörü de aynı
/// adı taşıyabildiği için önce geçici ada alınır; aksi halde ad çakışırdı.
Future<String> _finalize(String folder, TorrentModel model) async {
  final parent = p.dirname(folder);
  final name = sanitizeFileName(model.name);
  final inner = model.files.length == 1
      ? p.join(folder, p.joinAll(model.files.single.path.split('/')))
      : p.join(folder, model.name);
  final isFile = await File(inner).exists();
  if (!isFile && !await Directory(inner).exists()) {
    throw DiskException('İndirilen içerik bulunamadı: $inner');
  }

  final temp = await _uniqueFolder(p.join(parent, '$name.dmtmp'));
  await retryFileOperation(
    () async => isFile
        ? await File(inner).rename(temp)
        : await Directory(inner).rename(temp),
  );
  await retryFileOperation(() => Directory(folder).delete(recursive: true));

  final target = await _uniqueFilePath(p.join(parent, name));
  await retryFileOperation(
    () async => isFile
        ? await File(temp).rename(target)
        : await Directory(temp).rename(target),
  );
  return target;
}

Future<String> _uniqueFolder(String path) async {
  if (!await FileSystemEntity.isDirectory(path) &&
      !await FileSystemEntity.isFile(path)) {
    return path;
  }
  for (var i = 1;; i++) {
    final candidate = '$path ($i)';
    if (!await FileSystemEntity.isDirectory(candidate) &&
        !await FileSystemEntity.isFile(candidate)) {
      return candidate;
    }
  }
}

Future<String> _uniqueFilePath(String path) async {
  if (!await FileSystemEntity.isFile(path) &&
      !await FileSystemEntity.isDirectory(path)) {
    return path;
  }
  final dir = p.dirname(path);
  final stem = p.basenameWithoutExtension(path);
  final ext = p.extension(path);
  for (var i = 1;; i++) {
    final candidate = p.join(dir, '$stem ($i)$ext');
    if (!await FileSystemEntity.isFile(candidate) &&
        !await FileSystemEntity.isDirectory(candidate)) {
      return candidate;
    }
  }
}
