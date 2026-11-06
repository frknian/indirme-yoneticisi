import 'dart:io';

/// Yerel yama: bekleyen işlem varken `flush`/`close` hata atar. Hata yakalanıp tanıtıcı
/// unutulursa dosya açık kalır ve Windows taşımayı/silmeyi engeller. Bu yardımcı bekleyen
/// işlem bitene kadar yeniden dener ve tanıtıcıyı mutlaka kapatır.
Future<void> closeRandomAccess(
  RandomAccessFile? access, {
  bool flush = true,
  Duration retryDelay = const Duration(milliseconds: 20),
  int attempts = 250,
}) async {
  if (access == null) return;
  for (var attempt = 0; flush && attempt < attempts; attempt++) {
    try {
      await access.flush();
      break;
    } on FileSystemException {
      await Future<void>.delayed(retryDelay);
    }
  }
  for (var attempt = 0; attempt < attempts; attempt++) {
    try {
      await access.close();
      return;
    } on FileSystemException {
      await Future<void>.delayed(retryDelay);
    }
  }
}
