import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dm_core/dm_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_server.dart';

const _fast = DownloadTuning(
  retry: RetryPolicy(
    maxAttempts: 5,
    baseDelay: Duration(milliseconds: 10),
    maxDelay: Duration(milliseconds: 50),
  ),
  minSegmentSize: 1024,
  idleTimeout: Duration(seconds: 3),
  progressInterval: Duration(milliseconds: 10),
  metadataInterval: Duration(milliseconds: 20),
  flushInterval: Duration(milliseconds: 10),
);

/// Range başlıklarının toplam bayt sayısı (`bytes=a-b`).
int rangeBytes(Iterable<String> ranges) => ranges.fold(0, (sum, range) {
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range)!;
      return sum + int.parse(match[2]!) - int.parse(match[1]!) + 1;
    });

void main() {
  late Directory dir;
  late TestServer server;
  final data = randomBytes(2 * 1024 * 1024 + 123);
  final dataHash = sha256.convert(data).toString();

  Future<TestServer> serve(TestServer s) async {
    server = s;
    await s.start();
    return s;
  }

  DownloadTask task({
    Uri? url,
    int segments = 8,
    String? expectedSha256,
    bool computeSha256 = false,
    String? fileName,
    DownloadTuning tuning = _fast,
  }) =>
      DownloadTask(
        DownloadRequest(
          url: url ?? server.uri,
          directory: dir.path,
          segments: segments,
          expectedSha256: expectedSha256,
          computeSha256: computeSha256,
          fileName: fileName,
        ),
        tuning: tuning,
      );

  Future<void> expectDownloaded(DownloadProgress result,
      {List<int>? bytes}) async {
    expect(result.state, DownloadState.completed, reason: '${result.error}');
    final file = File(result.filePath!);
    expect(sha256.convert(await file.readAsBytes()).toString(),
        sha256.convert(bytes ?? data).toString());
    expect(File(partPathFor(result.filePath!)).existsSync(), isFalse);
    expect(File(metaPathFor(result.filePath!)).existsSync(), isFalse);
  }

  /// [bytes] kadar inene dek bekler, sonra [action] çalıştırır.
  Future<void> whenDownloaded(
      DownloadTask t, int bytes, Future<void> Function() action) async {
    final reached = Completer<void>();
    final sub = t.progress.listen((event) {
      if (event.downloadedBytes >= bytes && !reached.isCompleted) {
        reached.complete();
      }
    });
    t.start();
    await reached.future.timeout(const Duration(seconds: 20));
    await sub.cancel();
    await action();
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dm_core_test');
  });

  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  group('çok parçalı indirme', () {
    test('dosyayı parçalayıp bütünlüğü bozmadan birleştirir', () async {
      await serve(
          TestServer(data, chunkDelay: const Duration(milliseconds: 1)));
      final t = task();
      final states = <DownloadState>{};
      final sub = t.progress.listen((e) => states.add(e.state));
      final result = await t.run();
      // Yayın akışı olayları eşzamansız iletir; son olayın ulaşmasını bekle.
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      await expectDownloaded(result);
      expect(result.segments, hasLength(8));
      expect(server.getRanges.whereType<String>(), hasLength(8));
      expect(server.maxConcurrentGets, greaterThan(1));
      expect(
          states,
          containsAll([
            DownloadState.probing,
            DownloadState.downloading,
            DownloadState.completed
          ]));
      expect(p.basename(result.filePath!), 'data.bin');
    });

    test('küçük dosyada gereksiz parça açmaz', () async {
      final small = randomBytes(1500);
      await serve(TestServer(small));
      final result = await task().run();
      await expectDownloaded(result, bytes: small);
      expect(result.segments, hasLength(1));
    });

    test('parça sayısı 16 ile sınırlanır', () {
      final request = DownloadRequest(
          url: Uri.parse('http://x/y'), directory: '.', segments: 99);
      expect(request.segments, 16);
    });

    test('yönlendirmeyi izler ve parçaları son adresten ister', () async {
      await serve(TestServer(data));
      final result = await task(url: server.path('/redirect')).run();
      await expectDownloaded(result);
      expect(result.segments.length, 8);
    });
  });

  group('tek bağlantıya düşme', () {
    test('Range desteklemeyen sunucu', () async {
      await serve(TestServer(data, supportRanges: false));
      final result = await task().run();
      await expectDownloaded(result);
      expect(result.segments, hasLength(1));
      expect(result.resumable, isFalse);
      expect(server.getRanges.last, isNull);
    });

    test('boyutu bilinmeyen akış (chunked)', () async {
      await serve(
          TestServer(data, sendContentLength: false, supportRanges: false));
      final result = await task().run();
      await expectDownloaded(result);
      expect(result.segments, hasLength(1));
      expect(result.totalBytes, data.length);
    });

    test('HEAD reddedilirse Range GET ile yoklar', () async {
      await serve(TestServer(data, allowHead: false));
      final result = await task().run();
      await expectDownloaded(result);
      expect(result.segments, hasLength(8));
    });

    test('Accept-Ranges yoksa da gerçek Range desteğini bulur', () async {
      await serve(TestServer(data, advertiseRanges: false));
      final result = await task().run();
      await expectDownloaded(result);
      expect(result.segments, hasLength(8));
    });

    test('Range var deyip 200 dönen sunucuda tek bağlantıya düşer', () async {
      await serve(TestServer(data, ignoreRangeHeader: true));
      final result = await task().run();
      await expectDownloaded(result);
      expect(result.segments, hasLength(1));
      expect(result.resumable, isFalse);
    });

    test('kopan Range\'siz indirme baştan yazılır, dosya bozulmaz', () async {
      var dropped = false;
      await serve(TestServer(data, supportRanges: false,
          intercept: (request, index) async {
        final isProbe = request.headers.value(HttpHeaders.rangeHeader) != null;
        if (isProbe || dropped) return false;
        dropped = true;
        await server.serveThenDrop(request, 300000);
        return true;
      }));
      final result = await task().run();
      await expectDownloaded(result);
      expect(dropped, isTrue);
      expect(server.getRanges.whereType<Null>().length, 2);
    });
  });

  group('duraklat / devam', () {
    test('devamda yalnızca eksik baytları ister', () async {
      await serve(
          TestServer(data, chunkDelay: const Duration(milliseconds: 4)));
      final t = task();
      await whenDownloaded(t, data.length ~/ 3, t.pause);
      expect(t.state, DownloadState.paused);

      final path = t.targetPath!;
      expect(File(partPathFor(path)).existsSync(), isTrue);
      final meta = (await MetadataStore(path).load())!;
      expect(meta.downloadedBytes, greaterThan(0));
      expect(t.current.downloadedBytes, meta.downloadedBytes);

      final firstRanges = server.getRanges.length;
      server.chunkDelay = Duration.zero;
      final result = await t.run();
      await expectDownloaded(result);

      final resumed =
          server.getRanges.sublist(firstRanges).whereType<String>().toList();
      expect(resumed, isNotEmpty);
      for (final segment
          in meta.segments.where((s) => s.downloaded > 0 && !s.isComplete)) {
        expect(resumed.any((r) => r.startsWith('bytes=${segment.nextByte}-')),
            isTrue,
            reason:
                '${segment.index}. parça ${segment.nextByte} baytından devam etmeli: $resumed');
      }
      expect(rangeBytes(resumed), data.length - meta.downloadedBytes);
    });

    test('ETag değiştiyse baştan başlar', () async {
      await serve(
          TestServer(data, chunkDelay: const Duration(milliseconds: 4)));
      final t = task();
      await whenDownloaded(t, data.length ~/ 4, t.pause);
      expect(t.state, DownloadState.paused);

      final newData = randomBytes(data.length + 500, seed: 7);
      server
        ..data = newData
        ..etag = '"v2"'
        ..chunkDelay = Duration.zero;
      final result = await t.run();
      await expectDownloaded(result, bytes: newData);
      expect(result.restarts, 1);
    });

    test('Last-Modified değiştiyse baştan başlar', () async {
      await serve(TestServer(data,
          etag: null,
          lastModified: 'Wed, 21 Oct 2026 07:28:00 GMT',
          chunkDelay: const Duration(milliseconds: 4)));
      final t = task();
      await whenDownloaded(t, data.length ~/ 4, t.pause);
      expect(t.state, DownloadState.paused);

      final newData = randomBytes(data.length, seed: 9);
      server
        ..data = newData
        ..lastModified = 'Wed, 28 Oct 2026 07:28:00 GMT'
        ..chunkDelay = Duration.zero;
      final result = await t.run();
      await expectDownloaded(result, bytes: newData);
      expect(result.restarts, 1);
    });

    test('indirme sırasında değişen dosya If-Range ile yakalanır', () async {
      final newData = randomBytes(data.length, seed: 11);
      var flipped = false;
      await serve(TestServer(data, intercept: (request, index) async {
        if (index == 3 && !flipped) {
          flipped = true;
          server
            ..data = newData
            ..etag = '"v2"';
        }
        return false;
      }, chunkDelay: const Duration(milliseconds: 1)));
      final result = await task().run();
      await expectDownloaded(result, bytes: newData);
      expect(result.restarts, greaterThanOrEqualTo(1));
    });

    test('iptal geçici dosyaları siler', () async {
      await serve(
          TestServer(data, chunkDelay: const Duration(milliseconds: 4)));
      final t = task();
      await whenDownloaded(t, 100000, t.cancel);
      expect(t.state, DownloadState.canceled);
      expect(dir.listSync(), isEmpty);
    });

    test('yeni görev aynı URL\'nin metadata\'sından devam eder', () async {
      await serve(
          TestServer(data, chunkDelay: const Duration(milliseconds: 4)));
      final first = task();
      await whenDownloaded(first, data.length ~/ 3, first.pause);
      final saved = first.current.downloadedBytes;
      expect(saved, greaterThan(0));

      server.chunkDelay = Duration.zero;
      final before = server.getRanges.length;
      final result = await task().run();
      await expectDownloaded(result);
      expect(p.basename(result.filePath!), 'data.bin');
      final resumed = server.getRanges.sublist(before).whereType<String>();
      expect(rangeBytes(resumed), lessThan(data.length));
    });

    test('bozuk metadata temizlenir ve indirme baştan yapılır', () async {
      await serve(TestServer(data));
      final target = p.join(dir.path, 'data.bin');
      await File(metaPathFor(target)).writeAsString('{bozuk');
      await File(partPathFor(target)).writeAsString('eski');
      final result = await task().run();
      await expectDownloaded(result);
      expect(p.basename(result.filePath!), 'data.bin');
    });
  });

  group('kopma ve yeniden deneme', () {
    test('kopan parça kaldığı yerden tamamlanır', () async {
      await serve(TestServer(data, intercept: (request, index) async {
        if (index >= 4) return false;
        await server.serveThenDrop(request, 50000);
        return true;
      }));
      final result = await task().run();
      await expectDownloaded(result);
      expect(server.getRanges.length, greaterThan(8));
    });

    test('429 Retry-After\'a uyar ve bağlantıyı azaltır', () async {
      var throttled = 0;
      await serve(TestServer(data, intercept: (request, index) async {
        if (throttled < 4) {
          throttled++;
          request.response.statusCode = 429;
          request.response.headers.set(HttpHeaders.retryAfterHeader, '0');
          await request.response.close();
          return true;
        }
        return false;
      }, chunkDelay: const Duration(milliseconds: 1)));
      final result = await task().run();
      await expectDownloaded(result);
      expect(throttled, 4);
    });

    test('503 sonrası bağlantı sınırı düşer', () async {
      var failures = 0;
      var active = 0;
      var maxActiveAfter = 0;
      await serve(TestServer(data, intercept: (request, index) async {
        if (failures < 8) {
          failures++;
          request.response.statusCode = 503;
          await request.response.close();
          return true;
        }
        active++;
        if (active > maxActiveAfter) maxActiveAfter = active;
        await server.sendRangeFor(request);
        active--;
        return true;
      }));
      final result = await task().run();
      await expectDownloaded(result);
      expect(maxActiveAfter, lessThan(8));
    });

    test('404 yeniden denenmez ve açık tipli hata verir', () async {
      await serve(
          TestServer(data, allowHead: false, intercept: (request, index) async {
        request.response.statusCode = 404;
        await request.response.close();
        return true;
      }));
      final result = await task().run();
      expect(result.state, DownloadState.failed);
      expect(result.error, isA<HttpStatusException>());
      expect((result.error! as HttpStatusException).statusCode, 404);
      expect(server.getRanges.length, 1);
    });

    test('deneme hakkı bitince başarısız olur, sonra devam edebilir', () async {
      var broken = true;
      await serve(TestServer(data, intercept: (request, index) async {
        if (!broken) return false;
        request.response.statusCode = 500;
        await request.response.close();
        return true;
      }));
      final t = task();
      final failed = await t.run();
      expect(failed.state, DownloadState.failed);
      expect(failed.error, isA<RetriesExhaustedException>());
      expect(File(metaPathFor(t.targetPath!)).existsSync(), isTrue);

      broken = false;
      await expectDownloaded(await t.run());
    });

    test('bağlanılamayan sunucu ağ hatası olarak raporlanır', () async {
      await serve(TestServer(data));
      final closed = server.uri;
      await server.stop();
      final result = await task(url: closed).run();
      expect(result.state, DownloadState.failed);
      expect(result.error, isA<RetriesExhaustedException>());
      expect((result.error! as RetriesExhaustedException).lastError,
          isA<NetworkException>());
      await serve(TestServer(data)); // tearDown için.
    });

    test('takılan bağlantı boşta kalma süresiyle yeniden denenir', () async {
      await serve(TestServer(data, intercept: (request, index) async {
        if (index != 0) return false;
        final end = data.length ~/ 8;
        request.response.statusCode = 206;
        request.response.headers
          ..set(HttpHeaders.contentRangeHeader, 'bytes 0-$end/${data.length}')
          ..contentLength = end + 1;
        request.response.add(data.sublist(0, 100));
        await request.response.flush();
        await Future<void>.delayed(const Duration(seconds: 2));
        return true;
      }));
      final result = await task(
        tuning: const DownloadTuning(
          retry: RetryPolicy(baseDelay: Duration(milliseconds: 10)),
          minSegmentSize: 1024,
          idleTimeout: Duration(milliseconds: 200),
          progressInterval: Duration(milliseconds: 10),
        ),
      ).run();
      await expectDownloaded(result);
    });
  });

  group('bağlantı ayarları', () {
    test('hız sınırına uyar ve dosyayı bozmaz', () async {
      final small = randomBytes(600 * 1024);
      await serve(TestServer(small));
      final stopwatch = Stopwatch()..start();
      final result = await task(
        segments: 4,
        tuning: const DownloadTuning(
          minSegmentSize: 1024,
          progressInterval: Duration(milliseconds: 10),
          maxBytesPerSecond: 400 * 1024,
        ),
      ).run();
      stopwatch.stop();
      await expectDownloaded(result, bytes: small);
      // 600 KiB, 400 KiB/sn ile en az 1,5 saniye sürer (ilk parçalar için pay bırakıldı).
      expect(stopwatch.elapsedMilliseconds, greaterThan(1200));
    });

    test('sınırlı indirme bekleme sırasında da hemen duraklar', () async {
      await serve(TestServer(data));
      final t = task(
        tuning: const DownloadTuning(
          minSegmentSize: 1024,
          progressInterval: Duration(milliseconds: 10),
          maxBytesPerSecond: 64 * 1024,
        ),
      );
      t.start();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      final stopwatch = Stopwatch()..start();
      await t.pause();
      expect(t.state, DownloadState.paused);
      expect(stopwatch.elapsedMilliseconds, lessThan(2000));
      await t.cancel();
    });

    test('proxy üzerinden indirir; hedef ad doğrudan çözülmese de', () async {
      await serve(TestServer(data));
      final result = await task(
        // .invalid hiçbir zaman çözülmez: istek ancak proxy'den geçerse başarılı olur.
        url: Uri.parse('http://hedef.invalid/files/data.bin'),
        tuning: DownloadTuning(
          minSegmentSize: 1024,
          retry: const RetryPolicy(maxAttempts: 1),
          progressInterval: const Duration(milliseconds: 10),
          proxy: '127.0.0.1:${server.uri.port}',
        ),
      ).run();
      await expectDownloaded(result);
      expect(result.segments, hasLength(8));
    });

    test('proxy biçimi doğrulanır', () {
      expect(isValidProxy('127.0.0.1:8080'), isTrue);
      expect(isValidProxy('proxy.sirket.com:3128'), isTrue);
      for (final bad in [
        '',
        'sunucu',
        'a:99999',
        'a:0',
        'a:80; DIRECT',
        'http://a:80',
      ]) {
        expect(isValidProxy(bad), isFalse, reason: bad);
      }
    });
  });

  group('hash doğrulama', () {
    test('doğru özet tamamlanır ve raporlanır', () async {
      await serve(TestServer(data));
      final result = await task(expectedSha256: dataHash.toUpperCase()).run();
      await expectDownloaded(result);
      expect(result.sha256, dataHash);
    });

    test('yanlış özet açık hata verir ve dosya bırakmaz', () async {
      await serve(TestServer(data));
      final result = await task(expectedSha256: 'a' * 64).run();
      expect(result.state, DownloadState.failed);
      expect(result.error, isA<HashMismatchException>());
      expect(dir.listSync(), isEmpty);
    });

    test('computeSha256 beklenen olmadan da özet verir', () async {
      await serve(TestServer(data));
      final result = await task(computeSha256: true).run();
      expect(result.sha256, dataHash);
    });
  });

  group('dosya adı', () {
    test('Content-Disposition içindeki dizin geçişi engellenir', () async {
      await serve(TestServer(data,
          contentDisposition: 'attachment; filename="../../evil.sh"'));
      final result = await task().run();
      await expectDownloaded(result);
      expect(p.dirname(result.filePath!), dir.path);
      expect(p.basename(result.filePath!), 'evil.sh');
    });

    test('UTF-8 filename* okunur', () async {
      await serve(TestServer(data,
          contentDisposition:
              "attachment; filename=\"x.bin\"; filename*=UTF-8''%C3%B6rnek%20dosya.bin"));
      final result = await task().run();
      expect(p.basename(result.filePath!), 'örnek dosya.bin');
    });

    test('hedef doluysa üzerine yazmaz, yeni ad seçer', () async {
      await serve(TestServer(data));
      final existing = File(p.join(dir.path, 'data.bin'));
      await existing.writeAsString('değerli');
      final result = await task().run();
      await expectDownloaded(result);
      expect(p.basename(result.filePath!), 'data (1).bin');
      expect(await existing.readAsString(), 'değerli');
    });
  });

  test('ilerleme akışı artan bayt, hız ve kalan süre yayınlar', () async {
    await serve(TestServer(data, chunkDelay: const Duration(milliseconds: 3)));
    final t = task(segments: 4);
    final events = <DownloadProgress>[];
    final sub = t.progress.listen(events.add);
    await t.run();
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    final downloading =
        events.where((e) => e.state == DownloadState.downloading).toList();
    expect(downloading.length, greaterThan(3));
    expect(downloading.any((e) => e.bytesPerSecond > 0), isTrue);
    expect(downloading.any((e) => e.eta != null), isTrue);
    expect(downloading.any((e) => e.activeConnections > 1), isTrue);
    expect(events.last.fraction, 1.0);
  });

  test('metadata gizli başlıkları diske yazmaz', () {
    expect(
      jsonEncode(stripSensitiveHeaders(
          {'Cookie': 'a=b', 'AUTHORIZATION': 'x', 'Referer': 'r'})),
      '{"Referer":"r"}',
    );
  });
}
