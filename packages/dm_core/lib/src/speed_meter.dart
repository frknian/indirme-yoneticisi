import 'dart:collection';

/// Kayan pencere üzerinden hız ve kalan süre hesabı.
class SpeedMeter {
  SpeedMeter({
    this.window = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Duration window;
  final DateTime Function() _clock;
  final Queue<(DateTime, int)> _samples = Queue();
  int _windowBytes = 0;

  void add(int bytes) {
    if (bytes <= 0) return;
    final now = _clock();
    _samples.addLast((now, bytes));
    _windowBytes += bytes;
    _evict(now);
  }

  /// Bayt/saniye. Yeterli örnek yoksa 0.
  double get bytesPerSecond {
    final now = _clock();
    _evict(now);
    if (_samples.isEmpty) return 0;
    final elapsed = now.difference(_samples.first.$1).inMicroseconds;
    // Tek örnekte süre sıfır çıkar; en az 250 ms sayarak sıçramayı önle.
    final micros = elapsed < 250000 ? 250000 : elapsed;
    return _windowBytes * 1000000 / micros;
  }

  /// Kalan süre; hız veya kalan bayt bilinmiyorsa null.
  Duration? eta(int? remainingBytes) {
    if (remainingBytes == null || remainingBytes < 0) return null;
    final speed = bytesPerSecond;
    if (speed <= 0) return null;
    return Duration(microseconds: (remainingBytes / speed * 1000000).round());
  }

  void reset() {
    _samples.clear();
    _windowBytes = 0;
  }

  void _evict(DateTime now) {
    while (_samples.isNotEmpty && now.difference(_samples.first.$1) > window) {
      _windowBytes -= _samples.removeFirst().$2;
    }
  }
}
