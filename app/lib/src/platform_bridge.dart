import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

/// Android'e özgü işlevlerin köprüsü. Masaüstünde hiçbir şey yapmaz.
class PlatformBridge {
  PlatformBridge() {
    if (Platform.isAndroid) _channel.setMethodCallHandler(_onCall);
  }

  static const MethodChannel _channel = MethodChannel('dm/platform');

  final StreamController<String> _sharedUrls = StreamController.broadcast();
  final StreamController<void> _pauseAll = StreamController.broadcast();

  /// Paylaş menüsü veya link intent'i ile gelen adresler.
  Stream<String> get sharedUrls => _sharedUrls.stream;

  /// Bildirimdeki "Tümünü duraklat" düğmesi veya servis zaman aşımı.
  Stream<void> get pauseAllRequests => _pauseAll.stream;

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'sharedUrl':
        final url = call.arguments as String?;
        if (url != null) _sharedUrls.add(url);
      case 'pauseAll':
        _pauseAll.add(null);
    }
  }

  /// Uygulama açılırken bekleyen paylaşımı alır.
  Future<String?> takePendingSharedUrl() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('takePendingSharedUrl');
  }

  /// Android 13+ bildirim izni; önceki sürümlerde ve masaüstünde true döner.
  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('requestNotificationPermission') ??
        false;
  }

  /// Foreground service'i başlatır veya bildirimini günceller.
  /// Sistem izin vermezse false döner (ör. uygulama arka plandayken ilk başlatma).
  Future<bool> updateForeground({
    required String title,
    required String text,
    int? percent,
  }) async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('updateForeground', {
          'title': title,
          'text': text,
          'percent': percent,
        }) ??
        false;
  }

  Future<void> stopForeground() async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<void>('stopForeground');
  }

  /// Dosyayı MediaStore ile herkese açık İndirilenler'e taşır.
  /// Android 9 ve altında null döner; dosya uygulama klasöründe kalır.
  Future<String?> publishToDownloads(String path, String displayName) async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('publishToDownloads', {
      'path': path,
      'name': displayName,
    });
  }
}
