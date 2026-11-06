import 'package:dm_core/dm_core.dart';

String formatBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours} sa ${d.inMinutes % 60} dk';
  if (d.inMinutes > 0) return '${d.inMinutes} dk ${d.inSeconds % 60} sn';
  return '${d.inSeconds} sn';
}

String stateLabel(DownloadState state) => switch (state) {
  DownloadState.queued => 'Sırada',
  DownloadState.probing => 'Bağlanıyor',
  DownloadState.downloading => 'İndiriliyor',
  DownloadState.paused => 'Duraklatıldı',
  DownloadState.verifying => 'Doğrulanıyor',
  DownloadState.converting => 'Dönüştürülüyor',
  DownloadState.completed => 'Tamamlandı',
  DownloadState.failed => 'Başarısız',
  DownloadState.canceled => 'İptal edildi',
};

/// Listede görünen tek satırlık özet.
String progressSummary(DownloadProgress p) {
  final parts = <String>[];
  final total = p.totalBytes;
  parts.add(
    total == null
        ? formatBytes(p.downloadedBytes)
        : '${formatBytes(p.downloadedBytes)} / ${formatBytes(total)}',
  );
  if (p.state == DownloadState.downloading) {
    parts.add('${formatBytes(p.bytesPerSecond.round())}/sn');
    if (p.isTorrent) parts.add('${p.peers} eş');
    if (p.eta != null) parts.add('kalan ${formatDuration(p.eta!)}');
  } else {
    parts.add(stateLabel(p.state));
  }
  return parts.join('  •  ');
}

/// Hataları kullanıcıya uygun Türkçe metne çevirir.
String errorMessage(DownloadException error) => switch (error) {
  HttpStatusException(:final statusCode) => switch (statusCode) {
    401 || 403 =>
      'Sunucu erişimi reddetti (HTTP $statusCode). '
          'Bağlantı oturum gerektiriyor olabilir.',
    404 || 410 => 'Dosya sunucuda bulunamadı (HTTP $statusCode).',
    _ => 'Sunucu hatası (HTTP $statusCode).',
  },
  NetworkException() => 'Bağlantı sorunu: ${error.message}',
  RetriesExhaustedException(:final attempts, :final lastError) =>
    '$attempts denemeden sonra vazgeçildi. ${errorMessage(lastError)}',
  HashMismatchException() =>
    'SHA-256 uyuşmuyor; dosya bozuk veya farklı olabilir.',
  DiskFullException() => 'Diskte yer kalmadı.',
  _ => error.message,
};
