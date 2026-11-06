import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'exceptions.dart';

/// Tarayıcı eklentisinden gelen indirme isteği.
class CaptureRequest {
  const CaptureRequest({required this.url, this.fileName, this.referer});

  final Uri url;
  final String? fileName;
  final String? referer;
}

/// Yalnızca loopback'e bağlanan yerel sunucu; Chrome eklentisinden link alır.
///
/// Herhangi bir web sitesi tarayıcı üzerinden localhost'a istek gönderebildiği
/// için istekler şu sırayla süzülür:
/// 1. `Host` loopback olmalı (DNS rebinding'e karşı).
/// 2. `Origin` varsa `chrome-extension://` olmalı (web sayfalarını eler).
/// 3. `X-DM-Token` eşleştirme anahtarıyla aynı olmalı (diğer yerel süreçler için).
class CaptureServer {
  CaptureServer({
    required this.token,
    required this.onRequest,
    this.port = defaultPort,
  }) {
    if (token.length < 16) {
      throw ArgumentError.value(token, 'token', 'en az 16 karakter olmalı');
    }
  }

  static const int defaultPort = 38765;
  static const int _maxBodyBytes = 64 * 1024;
  static const String tokenHeader = 'x-dm-token';

  final String token;
  final int port;

  /// İstek kabul edilince çağrılır.
  final FutureOr<void> Function(CaptureRequest request) onRequest;

  HttpServer? _server;
  StreamSubscription<HttpRequest>? _subscription;

  bool get isRunning => _server != null;

  /// Gerçekte dinlenen port ([port] 0 ise işletim sistemi seçer).
  int? get boundPort => _server?.port;

  /// Kriptografik olarak güçlü eşleştirme anahtarı üretir.
  static String generateToken() {
    final random = Random.secure();
    return List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<void> start() async {
    if (_server != null) return;
    try {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      _subscription = server.listen(_handle);
    } on SocketException catch (e) {
      throw CaptureServerException(
        'Yerel sunucu $port portunda başlatılamadı',
        cause: e,
      );
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (!_hostAllowed(request)) {
        return await _reply(response, HttpStatus.forbidden, 'host_not_allowed');
      }
      final origin = request.headers.value('origin');
      if (origin != null && !origin.startsWith('chrome-extension://')) {
        return await _reply(
            response, HttpStatus.forbidden, 'origin_not_allowed');
      }
      if (origin != null) {
        response.headers
          ..set('Access-Control-Allow-Origin', origin)
          ..set('Vary', 'Origin');
      }

      if (request.method == 'OPTIONS') {
        response.headers
          ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
          ..set('Access-Control-Allow-Headers', 'content-type, x-dm-token');
        response.statusCode = HttpStatus.noContent;
        return await response.close();
      }

      if (!_tokenMatches(request.headers.value(tokenHeader))) {
        return await _reply(response, HttpStatus.unauthorized, 'bad_token');
      }

      final path = request.uri.path;
      if (request.method == 'GET' && path == '/ping') {
        return await _reply(response, HttpStatus.ok, 'ok');
      }
      if (request.method == 'POST' && path == '/download') {
        return await _handleDownload(request);
      }
      await _reply(response, HttpStatus.notFound, 'not_found');
    } on Object catch (e) {
      // Tek bir bozuk istek sunucuyu düşürmemeli.
      try {
        await _reply(response, HttpStatus.internalServerError, 'internal: $e');
      } on Object {
        // Yanıt zaten kapanmış.
      }
    }
  }

  Future<void> _handleDownload(HttpRequest request) async {
    final response = request.response;
    if (request.headers.contentType?.mimeType != 'application/json') {
      return _reply(response, HttpStatus.unsupportedMediaType, 'json_required');
    }
    final bytes = <int>[];
    var received = 0;
    // Sınır aşılsa da gövde sonuna kadar okunur: okunmamış veriyle kapatılan soket
    // Windows'ta RST gönderir ve istemci 413 yanıtını göremez. Bellekte tutulmaz.
    await for (final chunk in request) {
      received += chunk.length;
      if (received <= _maxBodyBytes) bytes.addAll(chunk);
    }
    if (received > _maxBodyBytes) {
      return _reply(response, HttpStatus.requestEntityTooLarge, 'too_large');
    }
    final CaptureRequest capture;
    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final url = Uri.parse(json['url'] as String);
      final isWeb = (url.isScheme('http') || url.isScheme('https')) &&
          url.host.isNotEmpty;
      if (!isWeb && !url.isScheme('magnet')) {
        return await _reply(response, HttpStatus.badRequest, 'bad_url');
      }
      capture = CaptureRequest(
        url: url,
        fileName: json['fileName'] as String?,
        referer: _validReferer(json['referer'] as String?),
      );
    } on FormatException {
      return _reply(response, HttpStatus.badRequest, 'bad_json');
    } on TypeError {
      return _reply(response, HttpStatus.badRequest, 'bad_json');
    }
    await onRequest(capture);
    await _reply(response, HttpStatus.accepted, 'accepted');
  }

  String? _validReferer(String? value) {
    if (value == null) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return uri.toString();
  }

  bool _hostAllowed(HttpRequest request) {
    final host = request.headers.value(HttpHeaders.hostHeader);
    if (host == null) return false;
    final name = host.split(':').first.toLowerCase();
    return name == '127.0.0.1' || name == 'localhost';
  }

  /// Zamanlama saldırısını önlemek için sabit süreli karşılaştırma.
  bool _tokenMatches(String? provided) {
    if (provided == null || provided.length != token.length) return false;
    var diff = 0;
    for (var i = 0; i < token.length; i++) {
      diff |= token.codeUnitAt(i) ^ provided.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _reply(HttpResponse response, int status, String code) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'status': code}));
    await response.close();
  }
}
