import 'dart:io';

/// Windows'ta antivirüs veya indeksleyici yeni yazılan dosyayı kısa süreliğine
/// kilitleyebilir. `ERROR_ACCESS_DENIED` (5), `ERROR_SHARING_VIOLATION` (32) ve
/// `ERROR_LOCK_VIOLATION` (33) bu yüzden geçici sayılır. POSIX'te yeniden denenmez.
bool isTransientFileLock(FileSystemException error) {
  if (!Platform.isWindows) return false;
  return const {5, 32, 33}.contains(error.osError?.errorCode);
}

/// Dosya işlemini geçici kilit hatalarında üstel beklemeyle yeniden dener.
/// Son denemede veya kalıcı hatada özgün hata fırlatılır.
Future<void> retryFileOperation(
  Future<void> Function() operation, {
  int attempts = 8,
  Duration initialDelay = const Duration(milliseconds: 50),
  bool Function(FileSystemException error) isRetryable = isTransientFileLock,
}) async {
  var delay = initialDelay;
  for (var attempt = 1;; attempt++) {
    try {
      await operation();
      return;
    } on FileSystemException catch (error) {
      if (attempt >= attempts || !isRetryable(error)) rethrow;
      await Future<void>.delayed(delay);
      delay *= 2;
    }
  }
}
