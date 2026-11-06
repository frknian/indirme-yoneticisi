import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:dm_core/src/media.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_server.dart';

void main() {
  late Directory toolDir;
  late Directory dir;
  late String fake;
  late String fakeFfmpeg;

  setUpAll(() async {
    toolDir = await Directory.systemTemp.createTemp('dm_fake_tool');
    fake = p.join(toolDir.path, Platform.isWindows ? 'yt-dlp.exe' : 'yt-dlp');
    fakeFfmpeg = p.join(toolDir.path, 'ffmpeg-sahte');
    File(fakeFfmpeg).writeAsStringSync('');
    final compile = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/support/fake_yt_dlp.dart',
      '-o',
      fake,
    ]);
    if (compile.exitCode != 0) {
      throw StateError('${compile.stdout}${compile.stderr}');
    }
  });

  tearDownAll(() => toolDir.delete(recursive: true));

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dm_media_test');
  });
  tearDown(() => dir.delete(recursive: true));

  DownloadTuning tuning({String? proxy, int rate = 0}) => DownloadTuning(
        ytDlpPath: fake,
        ffmpegPath: fakeFfmpeg,
        proxy: proxy,
        maxBytesPerSecond: rate,
      );

  DownloadTask task(
    String path, {
    MediaOptions media = const MediaOptions(),
    DownloadTuning? using,
  }) =>
      DownloadTask(
        DownloadRequest(
          url: Uri.parse('http://fake.invalid$path'),
          directory: dir.path,
          media: media,
        ),
        tuning: using ?? tuning(),
      );

  List<String> lastArgs() =>
      (jsonDecode(File('$fake.args').readAsStringSync()) as List<dynamic>)
          .cast<String>();

  group('indirme', () {
    test('MP4 dosyayı bitirir, geçici klasör kalmaz', () async {
      final t = task('/ok');
      final states = <DownloadState>{};
      final sub = t.progress.listen((e) => states.add(e.state));
      final result = await t.run();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(result.state, DownloadState.completed, reason: '${result.error}');
      expect(result.isMedia, isTrue);
      expect(p.basename(result.filePath!), 'Başlık [id].mp4');
      expect(File(result.filePath!).existsSync(), isTrue);
      expect(states, contains(DownloadState.converting));
      expect(states, contains(DownloadState.downloading));
      final left = dir.listSync().map((e) => p.basename(e.path));
      expect(left, ['Başlık [id].mp4']);
      expect(lastArgs(),
          containsAll(['--merge-output-format', 'mp4', '--recode-video']));
      expect(lastArgs(), isNot(contains('-x')));
    });

    test('MP3 ses çıkarır', () async {
      final result = await task(
        '/ok',
        media: const MediaOptions(format: MediaFormat.mp3),
      ).run();
      expect(result.state, DownloadState.completed, reason: '${result.error}');
      expect(p.extension(result.filePath!), '.mp3');
      expect(lastArgs(), containsAll(['-x', '--audio-format', 'mp3']));
    });

    test('kalite sınırı ve bağlantı ayarları aktarılır', () async {
      await task(
        '/ok',
        media: const MediaOptions(maxHeight: 720),
        using: tuning(proxy: '127.0.0.1:3128', rate: 2048),
      ).run();
      final args = lastArgs();
      expect(args.join(' '), contains('res:720'));
      expect(args.join(' '), contains('--proxy http://127.0.0.1:3128'));
      expect(args.join(' '), contains('--limit-rate 2048'));
      expect(args.join(' '), contains('--ffmpeg-location $fakeFfmpeg'));
    });

    test('video ve ses akışları toplam ilerlemede birleşir', () async {
      final t = task('/twostream');
      final seen = <int>[];
      final sub = t.progress.listen((e) {
        if (e.state == DownloadState.downloading) seen.add(e.downloadedBytes);
      });
      final result = await t.run();
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(result.state, DownloadState.completed);
      expect(seen, orderedEquals([...seen]..sort()), reason: 'geri gitmemeli');
      expect(seen.last, greaterThanOrEqualTo(1400));
    });

    test('yeniden denemeden önce argümanlar güvenlidir', () {
      final args = buildMediaDownloadArgs(
        url: Uri.parse('http://a/-x --exec kotu'),
        options: const MediaOptions(),
        homeDir: 'h',
        tempDir: 't',
        ffmpeg: null,
      );
      expect(args, contains('--no-config'));
      expect(args.join(' '), contains('--playlist-items 1'));
      expect(args[args.length - 2], '--');
      expect(args, isNot(contains('--exec')));
    });
  });

  group('duraklat / iptal', () {
    Future<void> whenRunning(DownloadTask t) async {
      final reached = Completer<void>();
      final sub = t.progress.listen((e) {
        if (e.downloadedBytes > 0 && !reached.isCompleted) reached.complete();
      });
      t.start();
      await reached.future.timeout(const Duration(seconds: 20));
      await sub.cancel();
    }

    test('duraklatır, süreç biter, devamda yarım dosya kullanılır', () async {
      final t = task('/slow');
      await whenRunning(t);
      await t.pause();
      expect(t.state, DownloadState.paused);
      final temps = dir.listSync().whereType<Directory>().toList();
      expect(temps, hasLength(1), reason: 'yarım dosyalar korunmalı');

      File('$fake.resumed').deleteSync();
      await whenRunning(t);
      final marker = File('$fake.resumed');
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!marker.existsSync() || marker.readAsStringSync().isEmpty) {
        if (DateTime.now().isAfter(deadline)) fail('süreç başlamadı');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(marker.readAsStringSync(), 'true');
      await t.cancel();
      expect(t.state, DownloadState.canceled);
    });

    test('iptal yalnızca geçici klasörü siler', () async {
      final other = File(p.join(dir.path, 'baska.txt'))
        ..writeAsStringSync('değerli');
      final t = task('/slow');
      await whenRunning(t);
      await t.cancel();
      expect(t.state, DownloadState.canceled);
      expect(dir.listSync().map((e) => p.basename(e.path)), ['baska.txt']);
      expect(other.readAsStringSync(), 'değerli');
    });
  });

  group('hatalar', () {
    test('DRM açık tipli hata verir', () async {
      final result = await task('/drm').run();
      expect(result.state, DownloadState.failed);
      expect(result.error, isA<MediaDrmException>());
      expect(result.error!.message, contains('DRM'));
    });

    test('desteklenmeyen site ve oturum gereken video', () async {
      final a = await task('/unsupported').run();
      expect(a.error, isA<MediaDownloadException>());
      expect(a.error!.message, contains('desteklenmiyor'));
      final b = await task('/signin').run();
      expect(b.error!.message, contains('oturum'));
    });

    test('başarısız indirme boş geçici klasör bırakmaz', () async {
      await task('/drm').run();
      expect(dir.listSync(), isEmpty);
    });

    test('DRM platformu araç çalıştırılmadan reddedilir', () async {
      for (final url in [
        'https://www.netflix.com/title/1',
        'https://www.disneyplus.com/x',
        'https://tv.apple.com/x',
        'https://www.blutv.com/x',
      ]) {
        File('$fake.args').writeAsStringSync('[]');
        final result = await DownloadTask(
          DownloadRequest(
            url: Uri.parse(url),
            directory: dir.path,
            media: const MediaOptions(),
          ),
          tuning: tuning(),
        ).run();
        expect(result.error, isA<MediaDrmException>(), reason: url);
        expect(lastArgs(), isEmpty, reason: 'araç çalışmamalı: $url');
        expect(dir.listSync(), isEmpty);
      }
      expect(isDrmPlatformUrl(Uri.parse('https://notnetflix.com/')), isFalse);
      expect(isDrmPlatformUrl(Uri.parse('https://youtube.com/')), isFalse);
    });

    test('yol bildirilmezse tamamlandı sayılmaz', () async {
      final result = await task('/nofile').run();
      expect(result.state, DownloadState.failed);
      expect(result.error, isA<MediaDownloadException>());
    });

    test('araç yoksa kurulum komutunu söyler', () async {
      final tools = locateMediaTools(searchDirs: const []);
      expect(tools.isComplete, isFalse);
      expect(
        () => requireMediaTools(tools),
        throwsA(
          isA<MediaToolMissingException>().having(
            (e) => e.message,
            'message',
            allOf(contains('yt-dlp'), contains('ffmpeg')),
          ),
        ),
      );
    });

    test('çalıştırılamayan araç açık hata verir', () async {
      final result = await DownloadTask(
        DownloadRequest(
          url: Uri.parse('http://fake.invalid/ok'),
          directory: dir.path,
          media: const MediaOptions(),
        ),
        tuning: DownloadTuning(
          ytDlpPath: p.join(dir.path, 'yok'),
          ffmpegPath: fakeFfmpeg,
        ),
      ).run();
      expect(result.state, DownloadState.failed);
      expect(result.error, isA<MediaToolMissingException>());
    });
  });

  group('oynatma listesi', () {
    MediaToolPaths tools() => MediaToolPaths(ytDlp: fake, ffmpeg: fakeFfmpeg);

    test('öğeleri listeler, bozuk adresi atlar', () async {
      final info = await probeMedia(
        Uri.parse('http://fake.invalid/playlist'),
        tools(),
      );
      expect(info.isPlaylist, isTrue);
      expect(info.title, 'Örnek/Liste');
      expect(info.entries.map((e) => e.title), ['Bir', 'İki']);
    });

    test('tek video seçilince liste açılmaz', () async {
      final info = await probeMedia(
        Uri.parse('http://fake.invalid/playlist'),
        tools(),
        wholePlaylist: false,
      );
      expect(info.isPlaylist, isFalse);
      expect(lastArgs(), contains('--no-playlist'));
    });

    test('desteklenmeyen liste açık hata verir', () {
      expect(
        probeMedia(Uri.parse('http://fake.invalid/unsupported'), tools()),
        throwsA(isA<MediaDownloadException>()),
      );
    });
  });

  group('kuyruk', () {
    test('seçenekler kaydedilir, geri yüklenir ve tuning uygulanır', () async {
      final path = p.join(dir.path, 'q', 'queue.json');
      final queue = DownloadQueue(persistPath: path, tuning: tuning());
      final t = queue.add(DownloadRequest(
        url: Uri.parse('http://fake.invalid/ok'),
        directory: dir.path,
        media: const MediaOptions(format: MediaFormat.mp3, maxHeight: 480),
      ));
      while (t.state != DownloadState.completed) {
        if (t.state == DownloadState.failed) fail('${t.current.error}');
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await queue.dispose();

      final again = DownloadQueue(persistPath: path, tuning: tuning());
      await again.restore();
      final restored = again.tasks.single;
      expect(restored.request.media!.format, MediaFormat.mp3);
      expect(restored.request.media!.maxHeight, 480);
      expect(restored.state, DownloadState.completed);
      await again.dispose();
    });
  });

  group('ayrıştırma', () {
    test('ilerleme satırı', () {
      final e = parseMediaLine('DM downloading 500 NA 1000.0 250.5 2')!
          as MediaProgressEvent;
      expect(e.downloaded, 500);
      expect(e.total, 1000, reason: 'kesin boyut yoksa tahmin kullanılır');
      expect(e.bytesPerSecond, 250.5);
      expect(e.etaSeconds, 2);
      expect(parseMediaLine('[youtube] bilgi'), isNull);
      expect(parseMediaLine('DMPP started MoveFiles'), isNull);
      expect(
          parseMediaLine('DMPP started Merger'), isA<MediaConvertingEvent>());
    });

    test('bilinen video adresleri', () {
      for (final yes in [
        'https://www.youtube.com/watch?v=a',
        'https://youtu.be/a',
        'https://m.youtube.com/watch?v=a',
        'https://vimeo.com/1',
        'https://site.example/a/master.m3u8',
      ]) {
        expect(isLikelyMediaUrl(Uri.parse(yes)), isTrue, reason: yes);
      }
      for (final no in [
        'https://example.com/a.zip',
        'https://notyoutube.com/a',
        'magnet:?xt=urn:btih:a',
      ]) {
        expect(isLikelyMediaUrl(Uri.parse(no)), isFalse, reason: no);
      }
    });
  });

  test('web sayfası dosya sayılmaz, açık hata verir', () async {
    final server = TestServer(randomBytes(2048));
    await server.start();
    final html = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    html.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write('<html></html>');
      await request.response.close();
    });
    addTearDown(() async {
      await server.stop();
      await html.close(force: true);
    });
    final result = await DownloadTask(
      DownloadRequest(
        url: Uri.parse('http://127.0.0.1:${html.port}/watch'),
        directory: dir.path,
      ),
    ).run();
    expect(result.state, DownloadState.failed);
    expect(result.error, isA<NotAFileException>());
    expect(dir.listSync(), isEmpty);
  });
}
