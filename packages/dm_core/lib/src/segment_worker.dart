import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'exceptions.dart';
import 'metadata_store.dart';
import 'probe.dart';
import 'retry.dart';

/// Worker'ın başarısızlık türü. Sınırı geçen tipler sade tutulur.
enum WorkerFailureKind {
  /// Bağlantı koptu veya zaman aşımı; yeniden denenir.
  network,

  /// Sunucu hata kodu döndürdü.
  httpStatus,

  /// Range isteğine 200 döndü: sunucu aralıkları desteklemiyor.
  rangeIgnored,

  /// ETag değişti veya 416 geldi: dosya sunucuda değişmiş.
  remoteChanged,

  /// Disk hatası.
  disk,

  /// Diskte yer yok.
  diskFull,
}

/// Worker isolate'ın başlangıç ayarları.
class WorkerConfig {
  const WorkerConfig({
    required this.mainPort,
    required this.url,
    required this.partPath,
    required this.segmentIndex,
    required this.start,
    required this.end,
    required this.alreadyDownloaded,
    required this.useRange,
    required this.headers,
    required this.idleTimeout,
    required this.connectionTimeout,
    required this.reportInterval,
    required this.flushInterval,
    this.etag,
    this.lastModified,
    this.userAgent,
    this.proxy,
    this.maxBytesPerSecond = 0,
  });

  final SendPort mainPort;
  final String url;
  final String partPath;
  final int segmentIndex;
  final int start;

  /// Son bayt (dahil); bilinmiyorsa -1.
  final int end;
  final int alreadyDownloaded;
  final bool useRange;
  final Map<String, String> headers;
  final Duration idleTimeout;
  final Duration connectionTimeout;
  final Duration reportInterval;

  /// Bu aralıkla flush edilir; yalnız flush edilen bayt "dayanıklı" sayılır.
  final Duration flushInterval;
  final String? etag;
  final String? lastModified;
  final String? userAgent;
  final String? proxy;

  /// Bu parçanın payına düşen hız; 0 sınırsız.
  final int maxBytesPerSecond;
}

sealed class WorkerMessage {
  const WorkerMessage();
}

final class WorkerReady extends WorkerMessage {
  const WorkerReady(this.controlPort);
  final SendPort controlPort;
}

final class WorkerProgress extends WorkerMessage {
  const WorkerProgress({required this.live, required this.durable});

  /// Yazılan toplam bayt (ekranda gösterilir).
  final int live;

  /// Flush edilmiş bayt (metadata'ya yalnızca bu yazılır).
  final int durable;
}

final class WorkerDone extends WorkerMessage {
  const WorkerDone(this.downloaded);
  final int downloaded;
}

final class WorkerStopped extends WorkerMessage {
  const WorkerStopped(this.durable);
  final int durable;
}

final class WorkerFailed extends WorkerMessage {
  const WorkerFailed({
    required this.kind,
    required this.message,
    required this.durable,
    this.statusCode,
    this.retryAfter,
  });

  final WorkerFailureKind kind;
  final String message;
  final int durable;
  final int? statusCode;
  final Duration? retryAfter;
}

class _WorkerAbort implements Exception {
  const _WorkerAbort(this.kind, this.message,
      {this.statusCode, this.retryAfter});
  final WorkerFailureKind kind;
  final String message;
  final int? statusCode;
  final Duration? retryAfter;
}

/// Bir parçayı indirir. [Isolate.spawn] girişi olduğu için üst düzey fonksiyondur.
Future<void> segmentWorkerMain(WorkerConfig config) async {
  final control = ReceivePort();
  config.mainPort.send(WorkerReady(control.sendPort));

  final client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = config.connectionTimeout
    ..idleTimeout = const Duration(seconds: 5);
  if (config.userAgent != null) client.userAgent = config.userAgent;
  if (config.proxy != null) {
    client.findProxy = (_) => 'PROXY ${config.proxy}';
  }

  var stopRequested = false;
  final controlSub = control.listen((_) {
    stopRequested = true;
    // Bekleyen okumayı keser; akış hatası aşağıda "durduruldu" olarak işlenir.
    client.close(force: true);
  });

  // Range kullanılmıyorsa dosya başından yazılır, eski içerik geçersizdir.
  var durable = config.useRange ? config.alreadyDownloaded : 0;
  var written = durable;
  RandomAccessFile? file;

  void send(WorkerMessage message) => config.mainPort.send(message);

  try {
    file = await File(config.partPath).open(
      // append dosyayı silmeden açar; konum aşağıda ayarlanır.
      mode: config.useRange ? FileMode.append : FileMode.write,
    );
    await file.setPosition(config.useRange ? config.start + written : 0);

    final uri = Uri.parse(config.url);
    final request = await client.getUrl(uri).timeout(config.connectionTimeout);
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    config.headers.forEach(request.headers.set);
    if (config.useRange) {
      final from = config.start + written;
      request.headers.set(
        HttpHeaders.rangeHeader,
        config.end == -1 ? 'bytes=$from-' : 'bytes=$from-${config.end}',
      );
      // Dosya değiştiyse sunucu parça yerine 200 döndürür. Zayıf ETag If-Range'de
      // kullanılamaz, o durumda Last-Modified'a geçilir.
      final validator = _ifRangeValidator(config.etag, config.lastModified);
      if (validator != null) {
        request.headers.set(HttpHeaders.ifRangeHeader, validator);
      }
    }

    final response = await request.close().timeout(config.connectionTimeout);
    _checkResponse(response, config, written);

    final limiter = Stopwatch()..start();
    var limitedBytes = 0;
    var lastReport = DateTime.now();
    var lastFlush = lastReport;
    final expected = config.end == -1
        ? (config.useRange || response.contentLength < 0
            ? null
            : response.contentLength)
        : config.end - config.start + 1;

    final body = response.timeout(config.idleTimeout);
    await for (final chunk in body) {
      if (stopRequested) break;
      var data = chunk;
      if (expected != null && written + data.length > expected) {
        // Sunucu istenenden fazla gönderdi; komşu parçanın üzerine yazma.
        data = data.sublist(0, expected - written);
      }
      await file.writeFrom(data);
      written += data.length;

      if (config.maxBytesPerSecond > 0) {
        limitedBytes += data.length;
        final dueMs = limitedBytes * 1000 ~/ config.maxBytesPerSecond;
        // Kısa dilimlerle uyur ki düşük hızda bile durdurma isteği gecikmesin.
        while (!stopRequested && limiter.elapsedMilliseconds < dueMs) {
          final wait = dueMs - limiter.elapsedMilliseconds;
          await Future<void>.delayed(
            Duration(milliseconds: wait < 100 ? wait : 100),
          );
        }
      }

      final now = DateTime.now();
      if (now.difference(lastFlush) >= config.flushInterval) {
        await file.flush();
        durable = written;
        lastFlush = now;
      }
      if (now.difference(lastReport) >= config.reportInterval) {
        send(WorkerProgress(live: written, durable: durable));
        lastReport = now;
      }
      if (expected != null && written >= expected) break;
    }

    await file.flush();
    durable = written;

    if (stopRequested) {
      send(WorkerStopped(durable));
    } else if (expected != null && written < expected) {
      send(WorkerFailed(
        kind: WorkerFailureKind.network,
        message: 'Bağlantı erken kapandı ($written / $expected bayt)',
        durable: durable,
      ));
    } else {
      send(WorkerDone(durable));
    }
  } on _WorkerAbort catch (e) {
    send(WorkerFailed(
      kind: e.kind,
      message: e.message,
      durable: durable,
      statusCode: e.statusCode,
      retryAfter: e.retryAfter,
    ));
  } on FileSystemException catch (e) {
    final wrapped = wrapFileSystemError('Yazılamadı: ${config.partPath}', e);
    send(WorkerFailed(
      kind: wrapped is DiskFullException
          ? WorkerFailureKind.diskFull
          : WorkerFailureKind.disk,
      message: wrapped.message,
      durable: durable,
    ));
  } on Object catch (e) {
    // Durdurma isteği akışı hatayla keser; bu beklenen bir durumdur.
    durable = await _flushQuietly(file, durable, written);
    if (stopRequested) {
      send(WorkerStopped(durable));
    } else if (e is SocketException ||
        e is HttpException ||
        e is TimeoutException ||
        e is HandshakeException ||
        e is TlsException) {
      send(WorkerFailed(
        kind: WorkerFailureKind.network,
        message: '$e',
        durable: durable,
      ));
    } else {
      rethrow;
    }
  } finally {
    await controlSub.cancel();
    control.close();
    client.close(force: true);
    try {
      await file?.close();
    } on FileSystemException {
      // Kapatma hatası veri kaybı değildir: bayt sayımı flush'a dayanır.
    }
  }
}

Future<int> _flushQuietly(
  RandomAccessFile? file,
  int durable,
  int written,
) async {
  try {
    await file?.flush();
    return written;
  } on FileSystemException {
    return durable;
  }
}

String? _ifRangeValidator(String? etag, String? lastModified) {
  if (etag != null && !etag.startsWith('W/')) return etag;
  return lastModified;
}

void _checkResponse(
  HttpClientResponse response,
  WorkerConfig config,
  int written,
) {
  final status = response.statusCode;
  if (config.useRange) {
    if (status == HttpStatus.partialContent) {
      final expectedStart = config.start + written;
      final start = parseContentRangeStart(
        response.headers.value(HttpHeaders.contentRangeHeader),
      );
      if (start != expectedStart) {
        throw _WorkerAbort(
          WorkerFailureKind.rangeIgnored,
          'Sunucu yanlış aralık döndürdü: beklenen $expectedStart, gelen $start',
        );
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      if (config.etag != null && etag != null && etag != config.etag) {
        throw _WorkerAbort(
          WorkerFailureKind.remoteChanged,
          'ETag değişti: ${config.etag} -> $etag',
        );
      }
      return;
    }
    if (status == HttpStatus.ok) {
      // If-Range gönderdiysek bu, dosyanın değiştiği anlamına da gelebilir;
      // üst katman yeniden yoklayarak hangisi olduğunu ayırır.
      throw const _WorkerAbort(
        WorkerFailureKind.rangeIgnored,
        'Sunucu Range isteğine 200 döndürdü',
      );
    }
    if (status == HttpStatus.requestedRangeNotSatisfiable) {
      throw const _WorkerAbort(
        WorkerFailureKind.remoteChanged,
        'Sunucu aralığı reddetti (416); dosya değişmiş olabilir',
      );
    }
  } else if (status >= 200 && status < 300) {
    return;
  }
  throw _WorkerAbort(
    WorkerFailureKind.httpStatus,
    'Sunucu HTTP $status döndürdü',
    statusCode: status,
    retryAfter: isTransientStatus(status)
        ? parseRetryAfter(response.headers.value(HttpHeaders.retryAfterHeader))
        : null,
  );
}
