import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dm_core/dm_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/test_server.dart';

/// Gerçek bir süreci SIGKILL ile öldürür: hiçbir temizlik kodu çalışamaz.
void main() {
  late Directory dir;
  late TestServer server;
  final data = randomBytes(6 * 1024 * 1024);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('dm_crash_test');
    server = TestServer(
      data,
      chunkDelay: const Duration(milliseconds: 25),
    );
    await server.start();
  });

  tearDown(() async {
    await server.stop();
    // Windows, öldürülen sürecin dosya kilidini hemen bırakmayabilir.
    await retryFileOperation(() => dir.delete(recursive: true));
  });

  Future<Process> startCli() => Process.start(Platform.resolvedExecutable, [
        'bin/cli.dart',
        server.uri.toString(),
        '-o',
        dir.path,
        '-s',
        '4',
      ]);

  Future<ProcessResult> cliToEnd() => Process.run(Platform.resolvedExecutable, [
        'bin/cli.dart',
        server.uri.toString(),
        '-o',
        dir.path,
        '-s',
        '4',
      ]);

  test('SIGKILL sonrası .part ve .dmmeta ile devam eder', () async {
    final target = p.join(dir.path, 'data.bin');
    final metaFile = File(metaPathFor(target));

    final process = await startCli();
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());

    // Metadata en az bir miktar dayanıklı ilerleme kaydedene dek bekle.
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var saved = 0;
    while (saved == 0) {
      expect(DateTime.now().isBefore(deadline), isTrue,
          reason: 'metadata ilerlemesi kaydedilmedi');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (await metaFile.exists()) {
        final meta = await MetadataStore(target).load();
        saved = meta?.downloadedBytes ?? 0;
      }
    }

    expect(process.kill(ProcessSignal.sigkill), isTrue);
    await process.exitCode;

    final meta = (await MetadataStore(target).load())!;
    expect(meta.downloadedBytes, greaterThan(0));
    expect(meta.isComplete, isFalse);
    expect(File(partPathFor(target)).existsSync(), isTrue);
    expect(File(target).existsSync(), isFalse);

    // Kurtarma: yalnızca eksik baytlar istenir.
    final before = server.getRanges.length;
    server.chunkDelay = Duration.zero;
    final result = await cliToEnd();
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');

    final bytes = await File(target).readAsBytes();
    expect(sha256.convert(bytes).toString(), sha256.convert(data).toString());
    expect(metaFile.existsSync(), isFalse);

    final resumed = server.getRanges.sublist(before).whereType<String>();
    expect(resumed, isNotEmpty);
    var requested = 0;
    for (final range in resumed) {
      final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
      if (match == null) continue; // Yoklama isteği aralığı değil.
      requested += int.parse(match[2]!) - int.parse(match[1]!) + 1;
    }
    expect(requested, data.length - meta.downloadedBytes,
        reason: 'kaydedilen parçalar tekrar indirilmemeli');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('metadata dayanıklı olandan fazlasını iddia etmez', () async {
    // Kaydedilen her parça dökümü, diskteki gerçek veriyle eşleşmelidir.
    final target = p.join(dir.path, 'data.bin');
    final process = await startCli();
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    await Future<void>.delayed(const Duration(seconds: 3));
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;

    final meta = await MetadataStore(target).load();
    if (meta == null) return; // Çok erken öldü; iddia edilen bir şey yok.
    final part = await File(partPathFor(target)).open();
    try {
      for (final segment in meta.segments) {
        if (segment.downloaded == 0) continue;
        await part.setPosition(segment.start);
        final onDisk = await part.read(segment.downloaded);
        final expected =
            data.sublist(segment.start, segment.start + segment.downloaded);
        expect(base64.encode(onDisk), base64.encode(expected),
            reason: '${segment.index}. parça');
      }
    } finally {
      await part.close();
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
