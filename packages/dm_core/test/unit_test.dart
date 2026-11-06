import 'dart:io';
import 'dart:math';

import 'package:dm_core/dm_core.dart';
import 'package:dm_core/src/file_name.dart';
import 'package:dm_core/src/probe.dart';
import 'package:dm_core/src/retry.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('planSegments', () {
    test('dosyayı boşluksuz ve taşmasız kapsar', () {
      for (final (size, count) in [(100, 8), (7, 8), (1, 1), (1000003, 16)]) {
        final segments = planSegments(size, count);
        expect(segments.first.start, 0);
        expect(segments.last.end, size - 1);
        for (var i = 1; i < segments.length; i++) {
          expect(segments[i].start, segments[i - 1].end + 1);
        }
        expect(segments.fold<int>(0, (a, s) => a + s.length!), size);
      }
    });

    test('küçük parça sınırına uyar', () {
      expect(planSegments(10 * 1024, 8, minSegmentSize: 4096), hasLength(2));
      expect(planSegments(100, 8, minSegmentSize: 4096), hasLength(1));
    });

    test('geçersiz girdi reddedilir', () {
      expect(() => planSegments(0, 1), throwsArgumentError);
      expect(() => planSegments(1, 0), throwsArgumentError);
    });
  });

  group('RetryPolicy', () {
    const policy = RetryPolicy(
      baseDelay: Duration(seconds: 1),
      maxDelay: Duration(seconds: 8),
      jitter: 0,
    );

    test('üstel artar ve üst sınırda durur', () {
      expect(policy.delayFor(1), const Duration(seconds: 1));
      expect(policy.delayFor(2), const Duration(seconds: 2));
      expect(policy.delayFor(3), const Duration(seconds: 4));
      expect(policy.delayFor(10), const Duration(seconds: 8));
      expect(policy.delayFor(1000), const Duration(seconds: 8));
    });

    test('Retry-After önceliklidir ama sınırı aşmaz', () {
      expect(policy.delayFor(1, retryAfter: const Duration(seconds: 3)),
          const Duration(seconds: 3));
      expect(policy.delayFor(1, retryAfter: const Duration(hours: 1)),
          const Duration(seconds: 8));
    });

    test('sapma belirtilen aralıkta kalır', () {
      const jittered = RetryPolicy(
        baseDelay: Duration(seconds: 1),
        jitter: 0.5,
      );
      final random = Random(1);
      for (var i = 0; i < 100; i++) {
        final delay = jittered.delayFor(1, random: random).inMilliseconds;
        expect(delay, inInclusiveRange(500, 1500));
      }
    });

    test('Retry-After biçimleri', () {
      expect(parseRetryAfter('5'), const Duration(seconds: 5));
      expect(parseRetryAfter(null), isNull);
      expect(parseRetryAfter('saçma'), isNull);
      expect(
        parseRetryAfter(
          'Wed, 21 Oct 2026 07:28:30 GMT',
          now: DateTime.utc(2026, 10, 21, 7, 28, 0),
        ),
        const Duration(seconds: 30),
      );
    });

    test('hangi hatalar geçici', () {
      expect(isTransientError(HttpStatusException(503)), isTrue);
      expect(isTransientError(HttpStatusException(429)), isTrue);
      expect(isTransientError(HttpStatusException(404)), isFalse);
      expect(isTransientError(const NetworkException('x')), isTrue);
      expect(isTransientError(const DiskException('x')), isFalse);
    });
  });

  group('SpeedMeter', () {
    test('kayan pencerede hız ve kalan süre', () {
      var now = DateTime(2026);
      final meter = SpeedMeter(
        window: const Duration(seconds: 5),
        clock: () => now,
      );
      expect(meter.bytesPerSecond, 0);
      expect(meter.eta(100), isNull);

      for (var i = 0; i < 4; i++) {
        meter.add(1000);
        now = now.add(const Duration(seconds: 1));
      }
      expect(meter.bytesPerSecond, closeTo(1000, 1));
      expect(meter.eta(5000)!.inSeconds, closeTo(5, 1));
      expect(meter.eta(null), isNull);

      now = now.add(const Duration(seconds: 10));
      expect(meter.bytesPerSecond, 0);
    });
  });

  group('dosya adı', () {
    test('tehlikeli adlar temizlenir', () {
      final cases = {
        '../../etc/passwd': 'passwd',
        r'..\..\windows\system32\evil.dll': 'evil.dll',
        '/abs/path.txt': 'path.txt',
        '..': 'download',
        '.': 'download',
        '': 'download',
        '   ': 'download',
        'dosya.txt...': 'dosya.txt',
        'a<b>c:d"e|f?g*h.txt': 'a_b_c_d_e_f_g_h.txt',
        'CON': '_CON',
        'con.txt': '_con.txt',
        'LPT1.log': '_LPT1.log',
        'COM0.txt': 'COM0.txt',
        'normal dosya (1).zip': 'normal dosya (1).zip',
        'null\x00byte.txt': 'null_byte.txt',
      };
      cases.forEach((input, expected) {
        expect(sanitizeFileName(input), expected, reason: input);
      });
    });

    test('çok uzun ad uzantıyı koruyarak kısaltılır', () {
      final name = sanitizeFileName('${'ğ' * 500}.tar.gz');
      expect(name, endsWith('.gz'));
      expect(name.length, lessThan(200));
    });

    test('Content-Disposition biçimleri', () {
      final cases = <String, String?>{
        'attachment; filename="a b.zip"': 'a b.zip',
        'attachment; filename=a.zip': 'a.zip',
        'attachment; filename=a.zip; size=3': 'a.zip',
        'ATTACHMENT; FILENAME="B.ZIP"': 'B.ZIP',
        'attachment; filename="q\\"x.zip"': 'q"x.zip',
        "attachment; filename*=UTF-8''%e2%82%ac.txt": '€.txt',
        "attachment; filename=\"f.txt\"; filename*=UTF-8''g%20h.txt": 'g h.txt',
        "attachment; filename*=iso-8859-1'en'%A3.txt": '£.txt',
        "attachment; filename*=UTF-8''%ZZ; filename=yedek.txt": 'yedek.txt',
        'inline': null,
      };
      cases.forEach((input, expected) {
        expect(fileNameFromContentDisposition(input), expected, reason: input);
      });
      expect(fileNameFromContentDisposition(null), isNull);
    });

    test('URL\'den ad çıkarılır', () {
      expect(fileNameFromUri(Uri.parse('http://a/b/c%20d.zip?x=1')), 'c d.zip');
      expect(fileNameFromUri(Uri.parse('http://a/')), isNull);
    });
  });

  group('retryFileOperation', () {
    const locked = FileSystemException('kilitli', 'x', OSError('', 32));

    test('geçici kilit geçince başarılı olur', () async {
      var calls = 0;
      await retryFileOperation(
        () async {
          if (++calls < 3) throw locked;
        },
        initialDelay: Duration.zero,
        isRetryable: (_) => true,
      );
      expect(calls, 3);
    });

    test('deneme hakkı bitince özgün hatayı fırlatır', () async {
      var calls = 0;
      await expectLater(
        retryFileOperation(
          () async {
            calls++;
            throw locked;
          },
          attempts: 3,
          initialDelay: Duration.zero,
          isRetryable: (_) => true,
        ),
        throwsA(same(locked)),
      );
      expect(calls, 3);
    });

    test('kalıcı hata yeniden denenmez', () async {
      var calls = 0;
      await expectLater(
        retryFileOperation(
          () async {
            calls++;
            throw locked;
          },
          isRetryable: (_) => false,
        ),
        throwsA(same(locked)),
      );
      expect(calls, 1);
    });
  });

  group('Content-Range', () {
    test('toplam ve başlangıç okunur', () {
      expect(parseContentRangeTotal('bytes 0-0/1234'), 1234);
      expect(parseContentRangeTotal('bytes 0-0/*'), isNull);
      expect(parseContentRangeTotal(null), isNull);
      expect(parseContentRangeStart('bytes 200-300/1234'), 200);
    });
  });

  test('yalnızca http/https kabul edilir', () {
    validateDownloadUri(Uri.parse('https://a/b'));
    for (final bad in ['file:///x', 'ftp://a/b', 'http://', '/yerel/yol']) {
      expect(() => validateDownloadUri(Uri.parse(bad)),
          throwsA(isA<InvalidUrlException>()),
          reason: bad);
    }
  });

  group('MetadataStore', () {
    late Directory dir;
    late String target;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dm_meta_test');
      target = p.join(dir.path, 'f.bin');
    });
    tearDown(() => dir.delete(recursive: true));

    DownloadMetadata sample() => DownloadMetadata(
          url: 'http://a/f.bin',
          finalUrl: 'http://cdn/f.bin',
          targetPath: target,
          size: 100,
          acceptsRanges: true,
          etag: '"e"',
          segments: planSegments(100, 4)..first.downloaded = 10,
        );

    test('kaydeder ve geri yükler, geçici dosya bırakmaz', () async {
      final store = MetadataStore(target);
      expect(await store.load(), isNull);
      await store.save(sample());
      final loaded = (await store.load())!;
      expect(loaded.url, 'http://a/f.bin');
      expect(loaded.finalUrl, 'http://cdn/f.bin');
      expect(loaded.etag, '"e"');
      expect(loaded.downloadedBytes, 10);
      expect(loaded.segments, hasLength(4));
      expect(File('${store.metaPath}.tmp').existsSync(), isFalse);
    });

    test('bozuk ve tutarsız dosyalar açık hata verir', () async {
      final store = MetadataStore(target);
      final file = File(store.metaPath);
      for (final content in [
        '{bozuk',
        '[]',
        '{"version":1}',
        '{"version":99,"url":"x"}',
      ]) {
        await file.writeAsString(content);
        await expectLater(
          store.load(),
          throwsA(isA<MetadataCorruptException>()),
          reason: content,
        );
      }

      final overlapping = sample()..segments[1].downloaded = 9999;
      await store.save(overlapping);
      await expectLater(
        store.load(),
        throwsA(isA<MetadataCorruptException>()),
      );
    });
  });

  test('sha256OfFile bilinen değeri üretir', () async {
    final dir = await Directory.systemTemp.createTemp('dm_hash_test');
    addTearDown(() => dir.delete(recursive: true));
    final file = File(p.join(dir.path, 'x'))..writeAsStringSync('abc');
    expect(
      await sha256OfFile(file.path),
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
    expect(isValidSha256('A' * 64), isTrue);
    expect(isValidSha256('a' * 63), isFalse);
  });

  test('olmayan dosyanın özeti açık hata verir', () {
    expect(
      sha256OfFile('/olmayan/dosya'),
      throwsA(isA<DiskException>()),
    );
  });
}
