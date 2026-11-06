import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dm_core/dm_core.dart';
import 'package:dtorrent_task_v2/dtorrent_task_v2.dart'
    show TorrentEngineConfig, TorrentParser, isSafeTorrentPath;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_server.dart';
import 'support/torrent_fixtures.dart';

const _tuning = DownloadTuning(
  progressInterval: Duration(milliseconds: 50),
  torrent: TorrentSettings(dht: false, allowLoopbackPeers: true),
);

void main() {
  late Directory dir;
  late FakeTracker tracker;
  FakeSeeder? seeder;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dm_torrent_test');
    tracker = FakeTracker();
    await tracker.start();
  });

  tearDown(() async {
    await seeder?.stop();
    seeder = null;
    await tracker.stop();
    await dir.delete(recursive: true);
  });

  Future<Uri> writeTorrent(FakeTorrent torrent) async {
    final file = File(p.join(dir.path, 'girdi', 'x.torrent'));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(torrent.bytes);
    return file.uri;
  }

  Future<DownloadTask> startSeeded(
    FakeTorrent torrent, {
    Duration delay = Duration.zero,
    DownloadTuning tuning = _tuning,
    String out = 'cikti',
  }) async {
    seeder = FakeSeeder(torrent, delay: delay);
    await seeder!.start();
    tracker.peerPort = seeder!.port;
    return DownloadTask(
      DownloadRequest(
        url: await writeTorrent(torrent),
        directory: p.join(dir.path, out),
      ),
      tuning: tuning,
    );
  }

  group('uçtan uca', () {
    test('tek dosyalı torrent izleyici ve eşten iner, klasörsüz kalır',
        () async {
      final data = randomBytes(200 * 1024 + 7);
      final torrent = buildTorrent(
        name: 'dosya.bin',
        announce: tracker.announce,
        single: data,
      );
      final task = await startSeeded(torrent);
      final result = await task.run();

      expect(result.state, DownloadState.completed, reason: '${result.error}');
      expect(result.isTorrent, isTrue);
      expect(tracker.announces, greaterThan(0));
      expect(result.filePath, p.join(dir.path, 'cikti', 'dosya.bin'));
      expect(
        sha256.convert(await File(result.filePath!).readAsBytes()),
        sha256.convert(data),
      );
      expect(result.totalBytes, data.length);
      final left = Directory(p.join(dir.path, 'cikti')).listSync();
      expect(left.map((e) => p.basename(e.path)), ['dosya.bin']);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('çok dosyalı torrent alt klasörleriyle iner', () async {
      final a = randomBytes(40 * 1024, seed: 1);
      final b = randomBytes(30 * 1024 + 3, seed: 2);
      final torrent = buildTorrent(
        name: 'paket',
        announce: tracker.announce,
        files: {
          ['a.bin']: a,
          ['alt', 'b.bin']: b,
        },
      );
      final result = await (await startSeeded(torrent)).run();

      expect(result.state, DownloadState.completed, reason: '${result.error}');
      final root = p.join(dir.path, 'cikti', 'paket');
      expect(result.filePath, root);
      expect(await File(p.join(root, 'a.bin')).readAsBytes(), a);
      expect(await File(p.join(root, 'alt', 'b.bin')).readAsBytes(), b);
      final states =
          Directory(root).listSync().where((e) => e.path.endsWith('.bt.state'));
      expect(states, isEmpty, reason: 'durum dosyası temizlenmeli');
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('var olan dosyanın üzerine yazmaz', () async {
      final data = randomBytes(50 * 1024);
      final torrent = buildTorrent(
        name: 'dosya.bin',
        announce: tracker.announce,
        single: data,
      );
      final existing = File(p.join(dir.path, 'cikti', 'dosya.bin'));
      await existing.parent.create(recursive: true);
      await existing.writeAsString('değerli');
      final result = await (await startSeeded(torrent)).run();

      expect(result.state, DownloadState.completed, reason: '${result.error}');
      expect(await existing.readAsString(), 'değerli');
      expect(p.basename(result.filePath!), 'dosya (1).bin');
    }, timeout: const Timeout(Duration(minutes: 1)));
  });

  test('magnet: bilgi eşten alınır, özet doğrulanır ve dosya iner', () async {
    // Her çalıştırmada farklı özet: önbellek veya eski durum sonucu etkilemesin.
    final data = randomBytes(
      120 * 1024,
      seed: DateTime.now().microsecondsSinceEpoch & 0xffffff,
    );
    final torrent = buildTorrent(
      name: 'magnet.bin',
      announce: tracker.announce,
      single: data,
    );
    seeder = FakeSeeder(torrent);
    await seeder!.start();
    tracker.peerPort = seeder!.port;
    final magnet = Uri.parse(
      'magnet:?xt=urn:btih:${torrent.infoHashHex}'
      '&tr=${Uri.encodeComponent(tracker.announce.toString())}',
    );
    final result = await DownloadTask(
      DownloadRequest(url: magnet, directory: p.join(dir.path, 'cikti')),
      tuning: _tuning,
    ).run();
    expect(result.state, DownloadState.completed, reason: '${result.error}');
    expect(seeder!.metadataRequests, greaterThan(0));
    expect(await File(result.filePath!).readAsBytes(), data);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('kuyruk torrent eş ararken onu çalışan sayar', () async {
    // Eşi olmayan torrent: bilgi aşamasında kalır, sınırı doldurmalıdır.
    final queue = DownloadQueue(maxConcurrent: 1, tuning: _tuning);
    final first = queue.add(
      DownloadRequest(
        url: Uri.parse('magnet:?xt=urn:btih:${'a' * 40}'),
        directory: p.join(dir.path, 'cikti'),
      ),
    );
    final second = queue.add(
      DownloadRequest(
        url: Uri.parse('magnet:?xt=urn:btih:${'b' * 40}'),
        directory: p.join(dir.path, 'cikti'),
      ),
    );
    expect(first.state, DownloadState.probing);
    expect(second.state, DownloadState.queued);
    await queue.remove(first);
    await queue.remove(second);
    await queue.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('bitince hiçbir dosya tanıtıcısı açık kalmaz', () async {
    // Windows'ta açık tanıtıcı son adına taşımayı engeller. lsof ile her Unix'te görülür.
    final data = randomBytes(80 * 1024, seed: 21);
    final torrent = buildTorrent(
      name: 'tanitici.bin',
      announce: tracker.announce,
      single: data,
    );
    final result = await (await startSeeded(torrent)).run();
    expect(result.state, DownloadState.completed, reason: '${result.error}');

    final lsof = await Process.run('lsof', ['-p', '$pid', '-Fn']);
    final open = (lsof.stdout as String)
        .split('\n')
        .where((line) => line.contains(p.join(dir.path, 'cikti')));
    expect(open, isEmpty);
  }, testOn: '!windows', timeout: const Timeout(Duration(minutes: 1)));

  group('duraklat / iptal', () {
    test('devam ederken biten parçaları yeniden istemez', () async {
      final data = randomBytes(600 * 1024, seed: 3);
      final torrent = buildTorrent(
        name: 'dosya.bin',
        announce: tracker.announce,
        single: data,
      );
      final task = await startSeeded(
        torrent,
        delay: const Duration(milliseconds: 25),
      );

      final reached = Completer<void>();
      final sub = task.progress.listen((e) {
        if (e.downloadedBytes > 150 * 1024 && !reached.isCompleted) {
          reached.complete();
        }
      });
      task.start();
      await reached.future.timeout(const Duration(seconds: 40));
      await sub.cancel();
      await task.pause();
      expect(task.state, DownloadState.paused);

      final before = seeder!.blocksServed;
      final paused = task.current.downloadedBytes;
      seeder!.delay = Duration.zero;
      final result = await task.run();

      expect(result.state, DownloadState.completed, reason: '${result.error}');
      expect(await File(result.filePath!).readAsBytes(), data);
      final blocksAfter = seeder!.blocksServed - before;
      final total = (data.length / 16384).ceil();
      expect(blocksAfter, lessThan(total),
          reason: 'tamamı yeniden indirilmemeli');
      expect(paused, greaterThan(0));
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('iptal klasörü siler', () async {
      final torrent = buildTorrent(
        name: 'dosya.bin',
        announce: tracker.announce,
        single: randomBytes(600 * 1024, seed: 4),
      );
      final task = await startSeeded(
        torrent,
        delay: const Duration(milliseconds: 30),
      );
      final reached = Completer<void>();
      final sub = task.progress.listen((e) {
        if (e.downloadedBytes > 0 && !reached.isCompleted) reached.complete();
      });
      task.start();
      await reached.future.timeout(const Duration(seconds: 40));
      await sub.cancel();
      await task.cancel();

      expect(task.state, DownloadState.canceled);
      expect(Directory(p.join(dir.path, 'cikti')).listSync(), isEmpty);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('deleteTorrentFolder indirme klasörü dışını reddeder', () async {
      final outside = Directory(p.join(dir.path, 'korunan'))..createSync();
      await expectLater(
        deleteTorrentFolder(p.join(dir.path, 'cikti'), outside.path),
        throwsA(isA<DiskException>()),
      );
      expect(outside.existsSync(), isTrue);
    });
  });

  group('güvenlik', () {
    for (final (label, path) in [
      ('üst dizin', ['..', 'kacak.txt']),
      ('derin üst dizin', ['alt', '..', '..', 'kacak.txt']),
      ('ters bölü', [r'..\kacak.txt']),
      ('sürücü harfi', [r'C:\kacak.txt']),
    ]) {
      test('$label içeren torrent reddedilir, dışarı dosya yazılmaz', () async {
        final torrent = buildTorrent(
          name: 'kotu',
          announce: tracker.announce,
          files: {
            path: randomBytes(1024),
            ['normal.bin']: randomBytes(1024, seed: 5),
          },
        );
        final result = await (await startSeeded(torrent)).run();
        expect(result.state, DownloadState.failed);
        expect(result.error, isA<InvalidTorrentException>());
        expect(
          File(p.join(dir.path, 'cikti', 'kacak.txt')).existsSync(),
          isFalse,
        );
        expect(File(p.join(dir.path, 'kacak.txt')).existsSync(), isFalse);
        expect(seeder!.blocksServed, 0, reason: 'indirme hiç başlamamalı');
      });
    }

    test('bozuk torrent dosyası açık hata verir', () async {
      final file = File(p.join(dir.path, 'bozuk.torrent'));
      await file.writeAsString('bu bir torrent değil');
      final result = await DownloadTask(
        DownloadRequest(url: file.uri, directory: dir.path),
        tuning: _tuning,
      ).run();
      expect(result.state, DownloadState.failed);
      expect(result.error, isA<InvalidTorrentException>());
    });

    test('olmayan dosya ve geçersiz magnet açık hata verir', () async {
      for (final url in [
        Uri.file(p.join(dir.path, 'yok.torrent')),
        Uri.parse('magnet:?dn=ozetsiz'),
      ]) {
        final result = await DownloadTask(
          DownloadRequest(url: url, directory: dir.path),
          tuning: _tuning,
        ).run();
        expect(result.state, DownloadState.failed, reason: '$url');
        expect(result.error, isA<InvalidTorrentException>(), reason: '$url');
      }
    });

    test('UPnP varsayılan olarak kapalı', () {
      expect(const TorrentSettings().portForwarding, isFalse);
      expect(TorrentEngineConfig.portForwarding, isFalse);
    });

    test('isSafeTorrentPath sınırları', () {
      for (final safe in ['a.bin', 'alt/b.bin', '..gizli', 'a..b/c']) {
        expect(isSafeTorrentPath(safe), isTrue, reason: safe);
      }
      for (final bad in [
        '',
        '/etc/passwd',
        '../a',
        'a/../../b',
        r'a\b',
        'C:/a',
        'a//b',
        './a'
      ]) {
        expect(isSafeTorrentPath(bad), isFalse, reason: bad);
      }
    });
  });

  group('info-hash', () {
    test('ham info baytlarının SHA-1 özetidir', () {
      final torrent = buildTorrent(
        name: 'ozet',
        announce: Uri.parse('http://izleyici.invalid/a'),
        single: randomBytes(50000, seed: 6),
      );
      expect(TorrentParser.parseBytes(torrent.bytes).infoHash,
          torrent.infoHashHex);
    });

    test('info metni başka yerde geçse de doğru bölümü bulur', () {
      final info = <String, Object>{
        'length': 4,
        'name': 'info',
        'piece length': 16384,
        'pieces': sha1.convert([1, 2, 3, 4]).bytes,
      };
      final bytes = bencodeValue(<String, Object>{
        'announce': 'http://info.invalid/info',
        'comment': 'd4:info bir tuzak',
        'info': info,
      });
      final expected = sha1.convert(bencodeValue(info)).toString();
      expect(
        TorrentParser.parseBytes(Uint8List.fromList(bytes)).infoHash,
        expected,
      );
    });
  });

  test('isTorrentUri', () {
    for (final yes in [
      'magnet:?xt=urn:btih:abc',
      'https://a/b.TORRENT',
      'http://a/b.torrent',
      'file:///a/b.torrent',
    ]) {
      expect(isTorrentUri(Uri.parse(yes)), isTrue, reason: yes);
    }
    for (final no in [
      'https://a/b.zip',
      'https://a/torrent',
      'ftp://a/b.torrent'
    ]) {
      expect(isTorrentUri(Uri.parse(no)), isFalse, reason: no);
    }
  });

  test('kuyruk torrenti kaydeder ve tamamlananı geri yükler', () async {
    final data = randomBytes(80 * 1024, seed: 8);
    final torrent = buildTorrent(
      name: 'kayit.bin',
      announce: tracker.announce,
      single: data,
    );
    seeder = FakeSeeder(torrent);
    await seeder!.start();
    tracker.peerPort = seeder!.port;
    final path = p.join(dir.path, 'queue.json');
    final queue = DownloadQueue(persistPath: path, tuning: _tuning);
    final task = queue.add(
      DownloadRequest(
        url: await writeTorrent(torrent),
        directory: p.join(dir.path, 'cikti'),
      ),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 40));
    while (task.state != DownloadState.completed) {
      if (DateTime.now().isAfter(deadline)) fail('${task.current.error}');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await queue.dispose();

    final restored = DownloadQueue(persistPath: path, tuning: _tuning);
    await restored.restore();
    final again = restored.tasks.single;
    expect(again.state, DownloadState.completed);
    expect(again.current.filePath, p.join(dir.path, 'cikti', 'kayit.bin'));
    await restored.remove(again, deleteFile: true);
    expect(File(p.join(dir.path, 'cikti', 'kayit.bin')).existsSync(), isFalse);
    await restored.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));
}
