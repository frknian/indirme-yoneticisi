/// İndirme motorunun ürettiği tüm hatalar bu hiyerarşidedir.
sealed class DownloadException implements Exception {
  const DownloadException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => cause == null
      ? '$runtimeType: $message'
      : '$runtimeType: $message (neden: $cause)';
}

/// URL geçersiz veya şeması http/https değil.
final class InvalidUrlException extends DownloadException {
  const InvalidUrlException(super.message);
}

/// Sunucu başarısız bir HTTP durum kodu döndürdü.
final class HttpStatusException extends DownloadException {
  HttpStatusException(this.statusCode, {this.retryAfter, String? message})
      : super(message ?? 'Sunucu HTTP $statusCode döndürdü');

  final int statusCode;
  final Duration? retryAfter;
}

/// Bağlantı koptu, zaman aşımı oldu veya DNS çözülemedi.
final class NetworkException extends DownloadException {
  const NetworkException(super.message, {super.cause});
}

/// Yeniden denemeler tükendi; [lastError] son görülen hatadır.
final class RetriesExhaustedException extends DownloadException {
  RetriesExhaustedException(this.attempts, this.lastError)
      : super('$attempts denemeden sonra vazgeçildi: ${lastError.message}',
            cause: lastError);

  final int attempts;
  final DownloadException lastError;
}

/// Sunucudaki dosya indirme sırasında defalarca değişti.
final class RemoteFileChangedException extends DownloadException {
  const RemoteFileChangedException(super.message);
}

/// Disk okuma/yazma hatası.
final class DiskException extends DownloadException {
  const DiskException(super.message, {super.cause});
}

/// Diskte yer kalmadı.
final class DiskFullException extends DiskException {
  const DiskFullException(super.message, {super.cause});
}

/// SHA-256 özeti beklenen değerle eşleşmedi.
final class HashMismatchException extends DownloadException {
  HashMismatchException({required this.expected, required this.actual})
      : super('SHA-256 uyuşmuyor: beklenen $expected, bulunan $actual');

  final String expected;
  final String actual;
}

/// .dmmeta dosyası okunamadı veya tutarsız.
final class MetadataCorruptException extends DownloadException {
  const MetadataCorruptException(super.message, {super.cause});
}

/// Yerel yakalama sunucusu başlatılamadı (ör. port dolu).
final class CaptureServerException extends DownloadException {
  const CaptureServerException(super.message, {super.cause});
}

/// Torrent dosyası veya magnet bağlantısı geçersiz ya da güvensiz.
final class InvalidTorrentException extends DownloadException {
  const InvalidTorrentException(super.message, {super.cause});
}

/// Beklenmeyen, sınıflandırılamayan hata.
final class UnexpectedDownloadException extends DownloadException {
  const UnexpectedDownloadException(super.message, {super.cause});
}
