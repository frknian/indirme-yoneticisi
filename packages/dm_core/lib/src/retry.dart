import 'dart:math';

import 'exceptions.dart';

/// Üstel geri çekilme (exponential backoff) ayarları.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 8,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 60),
    this.jitter = 0.2,
  });

  /// Art arda başarısız deneme sınırı. İlerleme kaydedilince sayaç sıfırlanır.
  final int maxAttempts;
  final Duration baseDelay;
  final Duration maxDelay;

  /// 0..1 arası rastgele sapma oranı; bağlantıların aynı anda dönmesini önler.
  final double jitter;

  /// [attempt] 1'den başlar. Sunucu `Retry-After` verdiyse o süreye uyulur.
  Duration delayFor(int attempt, {Duration? retryAfter, Random? random}) {
    if (retryAfter != null) {
      return retryAfter > maxDelay ? maxDelay : retryAfter;
    }
    final exponent = min(attempt - 1, 30);
    final raw = baseDelay.inMicroseconds * pow(2, exponent);
    final capped = min(raw.toDouble(), maxDelay.inMicroseconds.toDouble());
    final spread = capped * jitter;
    final offset = ((random ?? _random).nextDouble() * 2 - 1) * spread;
    return Duration(microseconds: max(0, (capped + offset).round()));
  }

  static final _random = Random();
}

/// Bu HTTP kodları geçici sayılır ve yeniden denenir.
bool isTransientStatus(int status) => const {
      408,
      425,
      429,
      500,
      502,
      503,
      504,
    }.contains(status);

/// 429 ve 503, sunucunun yük altında olduğunu gösterir: bağlantı azaltılır.
bool isThrottleStatus(int status) => status == 429 || status == 503;

bool isTransientError(DownloadException error) => switch (error) {
      NetworkException() => true,
      HttpStatusException(:final statusCode) => isTransientStatus(statusCode),
      _ => false,
    };

/// `Retry-After` başlığını okur; saniye veya HTTP tarihi olabilir.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) return null;
  final trimmed = value.trim();
  final seconds = int.tryParse(trimmed);
  if (seconds != null) return seconds < 0 ? null : Duration(seconds: seconds);
  try {
    final date = _parseHttpDate(trimmed);
    final diff = date.difference((now ?? DateTime.now()).toUtc());
    return diff.isNegative ? Duration.zero : diff;
  } on FormatException {
    return null;
  }
}

DateTime _parseHttpDate(String value) {
  // Örnek: Wed, 21 Oct 2026 07:28:00 GMT
  final match = RegExp(
    r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
  ).firstMatch(value);
  if (match == null) throw const FormatException('HTTP tarihi değil');
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final month = months.indexOf(match[2]!) + 1;
  if (month == 0) throw const FormatException('Geçersiz ay');
  return DateTime.utc(
    int.parse(match[3]!),
    month,
    int.parse(match[1]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}
