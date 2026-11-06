import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import 'exceptions.dart';

/// Dosyanın SHA-256 özetini ayrı isolate'ta (UI'ı bloklamadan) hesaplar.
Future<String> sha256OfFile(String path) async {
  try {
    return await Isolate.run(() async {
      final digest = await sha256.bind(File(path).openRead()).first;
      return digest.toString();
    });
  } on FileSystemException catch (e) {
    throw DiskException('Özet hesaplanamadı: $path', cause: e);
  }
}

/// Karşılaştırma için onaltılık özeti normalize eder.
String normalizeSha256(String value) => value.trim().toLowerCase();

/// Geçerli bir SHA-256 onaltılık dizisi mi?
bool isValidSha256(String value) =>
    RegExp(r'^[0-9a-f]{64}$').hasMatch(normalizeSha256(value));
