import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:dm_core/dm_core.dart';

/// Çekirdeği komut satırından çalıştırır. Ctrl+C indirmeyi duraklatır; aynı komutu
/// tekrar çalıştırmak kaldığı yerden devam ettirir.
Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('output', abbr: 'o', help: 'İndirme klasörü', defaultsTo: '.')
    ..addOption('name', abbr: 'n', help: 'Dosya adı (varsayılan: sunucudan)')
    ..addOption(
      'segments',
      abbr: 's',
      help: 'Parça sayısı (1-$maxSegments)',
      defaultsTo: '$defaultSegments',
    )
    ..addOption('sha256', help: 'Beklenen SHA-256 özeti')
    ..addFlag('hash',
        help: 'SHA-256 özetini hesapla ve yazdır', negatable: false)
    ..addMultiOption('header', abbr: 'H', help: 'Ek başlık, örn. "Ad: Değer"')
    ..addOption('media',
        help: 'Video/ses olarak indir', allowed: ['mp4', 'mp3'])
    ..addOption('quality', help: 'En yüksek video yüksekliği, örn. 720')
    ..addFlag(
      'playlist',
      help: 'Oynatma listesinin tamamını indir (--media ile)',
      negatable: false,
    )
    ..addFlag('quiet', abbr: 'q', help: 'İlerleme yazdırma', negatable: false)
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    exitCode = 64;
    return;
  }
  if (args.flag('help') || args.rest.length != 1) {
    stdout.writeln('Kullanım: dart run bin/cli.dart <url> [seçenekler]\n');
    stdout.writeln(parser.usage);
    exitCode = args.flag('help') ? 0 : 64;
    return;
  }

  final segments = int.tryParse(args.option('segments')!);
  if (segments == null || segments < 1 || segments > maxSegments) {
    stderr.writeln('--segments 1 ile $maxSegments arasında olmalı');
    exitCode = 64;
    return;
  }
  final expected = args.option('sha256');
  if (expected != null && !isValidSha256(expected)) {
    stderr.writeln('--sha256 64 karakterlik onaltılık özet olmalı');
    exitCode = 64;
    return;
  }

  final headers = <String, String>{};
  for (final raw in args.multiOption('header')) {
    final colon = raw.indexOf(':');
    if (colon <= 0) {
      stderr.writeln('Geçersiz başlık: $raw');
      exitCode = 64;
      return;
    }
    headers[raw.substring(0, colon).trim()] = raw.substring(colon + 1).trim();
  }

  final mediaName = args.option('media');
  final media = mediaName == null
      ? null
      : MediaOptions(
          format: MediaFormat.values.byName(mediaName),
          maxHeight: int.tryParse(args.option('quality') ?? ''),
        );
  if (media != null && args.flag('playlist')) {
    await _downloadPlaylist(
      Uri.parse(args.rest.single),
      media,
      args.option('output')!,
    );
    return;
  }

  final task = DownloadTask(
    DownloadRequest(
      url: Uri.parse(args.rest.single),
      directory: args.option('output')!,
      fileName: args.option('name'),
      segments: segments,
      headers: headers,
      expectedSha256: expected,
      computeSha256: args.flag('hash'),
      media: media,
    ),
  );

  final quiet = args.flag('quiet');
  final interactive = stdout.hasTerminal;
  var lastLine = DateTime.fromMillisecondsSinceEpoch(0);
  final subscription = task.progress.listen((progress) {
    if (quiet || progress.state != DownloadState.downloading) return;
    final now = DateTime.now();
    final minGap = interactive
        ? const Duration(milliseconds: 200)
        : const Duration(seconds: 2);
    if (now.difference(lastLine) < minGap) return;
    lastLine = now;
    final line = _formatProgress(progress);
    if (interactive) {
      stdout.write('\r\x1B[K$line');
    } else {
      stdout.writeln(line);
    }
  });

  // Ctrl+C: temiz duraklat, metadata'yı kaydet.
  final sigint = ProcessSignal.sigint.watch().listen((_) {
    stdout.writeln('\nDuraklatılıyor...');
    unawaited(task.pause());
  });

  final result = await task.run();
  await subscription.cancel();
  await sigint.cancel();
  if (interactive && !quiet) stdout.write('\r\x1B[K');

  switch (result.state) {
    case DownloadState.completed:
      stdout.writeln('Tamamlandı: ${result.filePath}');
      stdout.writeln('Boyut: ${_formatBytes(result.downloadedBytes)}');
      stdout.writeln('Parça: ${result.segments.length}');
      if (result.sha256 != null) stdout.writeln('SHA-256: ${result.sha256}');
    case DownloadState.paused:
      stdout.writeln(
        'Duraklatıldı (${_formatBytes(result.downloadedBytes)}). '
        'Devam etmek için aynı komutu çalıştırın.',
      );
      exitCode = 130;
    case _:
      stderr.writeln('Başarısız: ${result.error}');
      exitCode = 1;
  }
  await task.dispose();
}

Future<void> _downloadPlaylist(
  Uri url,
  MediaOptions media,
  String output,
) async {
  final DownloadException? failure;
  try {
    final info = await probeMedia(url, locateMediaTools());
    final entries = info.isPlaylist
        ? info.entries
        : [MediaEntry(url: url, title: info.title)];
    stdout.writeln('${info.title}: ${entries.length} öğe');
    final directory = info.isPlaylist
        ? '$output${Platform.pathSeparator}${sanitizeFileName(info.title)}'
        : output;
    var failed = 0;
    for (final entry in entries) {
      final task = DownloadTask(
        DownloadRequest(url: entry.url, directory: directory, media: media),
      );
      final result = await task.run();
      stdout.writeln(
        result.state == DownloadState.completed
            ? 'Tamamlandı: ${result.filePath}'
            : 'Başarısız: ${entry.title}: ${result.error?.message}',
      );
      if (result.state != DownloadState.completed) failed++;
      await task.dispose();
    }
    if (failed > 0) exitCode = 1;
    return;
  } on DownloadException catch (e) {
    failure = e;
  }
  stderr.writeln('Başarısız: ${failure.message}');
  exitCode = 1;
}

String _formatProgress(DownloadProgress p) {
  final fraction = p.fraction;
  final percent =
      fraction == null ? '  ?%' : '${(fraction * 100).toStringAsFixed(1)}%';
  final total = p.totalBytes == null ? '?' : _formatBytes(p.totalBytes!);
  final eta = p.eta == null ? '--' : _formatDuration(p.eta!);
  return '$percent  ${_formatBytes(p.downloadedBytes)}/$total  '
      '${_formatBytes(p.bytesPerSecond.round())}/s  '
      'kalan $eta  ${p.activeConnections} bağlantı';
}

String _formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String _formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}sa ${d.inMinutes % 60}dk';
  if (d.inMinutes > 0) return '${d.inMinutes}dk ${d.inSeconds % 60}sn';
  return '${d.inSeconds}sn';
}
