import 'dart:async';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_server.dart';

const _fast = DownloadTuning(
  retry: RetryPolicy(baseDelay: Duration(milliseconds: 10)),
  minSegmentSize: 1024,
  progressInterval: Duration(milliseconds: 10),
  metadataInterval: Duration(milliseconds: 20),
  flushInterval: Duration(milliseconds: 10),
);

void main() {
  late Directory dir;
  late TestServer server;
  final data = randomBytes(400 * 1024);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dm_queue_test');
    server = TestServer(data, chunkDelay: const Duration(milliseconds: 5));
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    await dir.delete(recursive: true);
  });

  DownloadRequest request(String name) => DownloadRequest(
        url: server.path('/files/$name'),
        directory: dir.path,
        segments: 2,
      );

  Future<void> untilAllSettled(DownloadQueue queue) async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (queue.tasks
        .any((t) => t.state.isActive || t.state == DownloadState.queued)) {
      if (DateTime.now().isAfter(deadline)) fail('kuyruk bitmedi');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('eşzamanlılık sınırına uyar ve hepsini bitirir', () async {
    final queue = DownloadQueue(maxConcurrent: 2, tuning: _fast);
    var peak = 0;
    final sub = queue.changes.listen((_) {
      if (queue.activeCount > peak) peak = queue.activeCount;
    });
    for (var i = 0; i < 5; i++) {
      queue.add(request('f$i.bin'));
    }
    await untilAllSettled(queue);
    await sub.cancel();

    expect(peak, 2);
    expect(
        queue.tasks.map((t) => t.state), everyElement(DownloadState.completed));
    for (var i = 0; i < 5; i++) {
      expect(File(p.join(dir.path, 'f$i.bin')).lengthSync(), data.length);
    }
    await queue.dispose();
  });

  test('duraklatılan görev yer açar, devam edince tamamlanır', () async {
    final queue = DownloadQueue(maxConcurrent: 1, tuning: _fast);
    final first = queue.add(request('a.bin'));
    final second = queue.add(request('b.bin'));
    expect(second.state, DownloadState.queued);

    await queue.pause(first);
    expect(first.state, DownloadState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(second.state.isActive || second.state == DownloadState.completed,
        isTrue);

    queue.resume(first);
    await untilAllSettled(queue);
    expect(first.state, DownloadState.completed);
    expect(second.state, DownloadState.completed);
    await queue.dispose();
  });

  test('kuyruk listeyi kaydeder, açılışta çalışanları sürdürür', () async {
    final path = p.join(dir.path, 'state', 'queue.json');
    final queue =
        DownloadQueue(maxConcurrent: 1, persistPath: path, tuning: _fast);
    final done = queue.add(DownloadRequest(
      url: server.path('/files/done.bin'),
      directory: dir.path,
      segments: 2,
      headers: const {'Cookie': 'gizli=1', 'Referer': 'http://x/'},
    ));
    server.chunkDelay = Duration.zero;
    await untilAllSettled(queue);
    expect(done.state, DownloadState.completed);

    server.chunkDelay = const Duration(milliseconds: 10);
    final running = queue.add(request('running.bin'));
    final userPaused = queue.add(request('paused.bin'));
    await queue.pause(userPaused);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await queue.dispose();

    final raw = await File(path).readAsString();
    expect(raw, isNot(contains('gizli')), reason: 'çerez diske yazılmamalı');

    server.chunkDelay = Duration.zero;
    final restored =
        DownloadQueue(maxConcurrent: 2, persistPath: path, tuning: _fast);
    await restored.restore();
    expect(restored.tasks, hasLength(3));

    DownloadTask byId(String id) =>
        restored.tasks.firstWhere((t) => t.id == id);
    expect(byId(done.id).state, DownloadState.completed);
    expect(byId(userPaused.id).state, DownloadState.paused);

    await untilAllSettled(restored);
    final revived = byId(running.id);
    expect(revived.state, DownloadState.completed);
    expect(File(revived.current.filePath!).lengthSync(), data.length);
    expect(byId(userPaused.id).state, DownloadState.paused);
    await restored.dispose();
  });

  test('bozuk kayıt açık tipli hata verir', () async {
    final path = p.join(dir.path, 'queue.json');
    await File(path).writeAsString('[bozuk');
    final queue = DownloadQueue(persistPath: path);
    expect(queue.restore(), throwsA(isA<MetadataCorruptException>()));
  });

  test('remove tamamlanan dosyayı yalnızca istenirse siler', () async {
    final queue = DownloadQueue(tuning: _fast);
    server.chunkDelay = Duration.zero;
    final keep = queue.add(request('keep.bin'));
    final drop = queue.add(request('drop.bin'));
    await untilAllSettled(queue);

    await queue.remove(keep);
    await queue.remove(drop, deleteFile: true);
    expect(queue.tasks, isEmpty);
    expect(File(p.join(dir.path, 'keep.bin')).existsSync(), isTrue);
    expect(File(p.join(dir.path, 'drop.bin')).existsSync(), isFalse);
    await queue.dispose();
  });

  test('remove bitmemiş görevin geçici dosyalarını temizler', () async {
    final queue = DownloadQueue(tuning: _fast);
    final task = queue.add(request('temp.bin'));
    await queue.pause(task);
    await queue.remove(task);
    expect(dir.listSync().whereType<File>(), isEmpty);
    await queue.dispose();
  });
}
