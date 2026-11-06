import 'dart:async';
import 'dart:io';

import 'exceptions.dart';
import 'file_name.dart';
import 'retry.dart';

/// HEAD (gerekirse tek baytlık GET) ile öğrenilen dosya bilgileri.
class ProbeResult {
  const ProbeResult({
    required this.originalUri,
    required this.finalUri,
    required this.size,
    required this.acceptsRanges,
    required this.fileName,
    this.etag,
    this.lastModified,
    this.contentType,
  });

  final Uri originalUri;

  /// Yönlendirmeler izlendikten sonraki adres.
  final Uri finalUri;

  /// Bayt cinsinden boyut; bilinmiyorsa null.
  final int? size;
  final bool acceptsRanges;

  /// Temizlenmiş dosya adı.
  final String fileName;
  final String? etag;
  final String? lastModified;
  final String? contentType;

  /// Parçalı indirme ve kesintisiz devam ancak bu durumda mümkündür.
  bool get supportsSegments => acceptsRanges && size != null && size! > 0;
}

/// [uri] yalnızca http/https olabilir.
void validateDownloadUri(Uri uri) {
  if (!(uri.isScheme('http') || uri.isScheme('https')) || uri.host.isEmpty) {
    throw InvalidUrlException('Yalnızca http/https desteklenir: $uri');
  }
}

/// Sunucuyu yoklar. Önce `HEAD`; HEAD başarısızsa veya `Accept-Ranges`
/// belirsizse `Range: bytes=0-0` ile doğrular (bazı sunucular ve imzalı URL'ler
/// HEAD'i reddeder, bazıları Range desteğini başlıkta bildirmez).
Future<ProbeResult> probeUrl(
  Uri uri, {
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 20),
  String? userAgent,
  String? proxy,
}) async {
  validateDownloadUri(uri);
  final client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = timeout;
  if (userAgent != null) client.userAgent = userAgent;
  if (proxy != null) client.findProxy = (_) => 'PROXY $proxy';
  try {
    final head = await _send(client, 'HEAD', uri, headers, timeout);
    await head.response.drain<void>();
    final status = head.response.statusCode;

    if (isThrottleStatus(status)) {
      throw HttpStatusException(
        status,
        retryAfter: parseRetryAfter(
          head.response.headers.value(HttpHeaders.retryAfterHeader),
        ),
      );
    }

    final headOk = status >= 200 && status < 300;
    final acceptRanges = head.response.headers
        .value(HttpHeaders.acceptRangesHeader)
        ?.trim()
        .toLowerCase();
    final headSize = head.response.contentLength;

    if (headOk && acceptRanges == 'bytes' && headSize > 0) {
      return _result(uri, head, size: headSize, acceptsRanges: true);
    }
    if (headOk && acceptRanges == 'none') {
      return _result(
        uri,
        head,
        size: headSize > 0 ? headSize : null,
        acceptsRanges: false,
      );
    }

    // HEAD yetersiz: tek baytlık GET ile gerçek davranışı gör.
    final get = await _send(
      client,
      'GET',
      uri,
      {...headers, HttpHeaders.rangeHeader: 'bytes=0-0'},
      timeout,
    );
    final getStatus = get.response.statusCode;
    if (getStatus == HttpStatus.partialContent) {
      final total = parseContentRangeTotal(
        get.response.headers.value(HttpHeaders.contentRangeHeader),
      );
      await _discard(get.response);
      return _result(
        uri,
        get,
        size: total,
        // Toplam boyut bilinmeden parçalanamaz.
        acceptsRanges: total != null,
      );
    }
    if (getStatus >= 200 && getStatus < 300) {
      final size = get.response.contentLength;
      await _discard(get.response);
      return _result(uri, get,
          size: size > 0 ? size : null, acceptsRanges: false);
    }
    final retryAfter = parseRetryAfter(
      get.response.headers.value(HttpHeaders.retryAfterHeader),
    );
    await _discard(get.response);
    throw HttpStatusException(getStatus, retryAfter: retryAfter);
  } on SocketException catch (e) {
    throw NetworkException('Sunucuya bağlanılamadı: ${uri.host}', cause: e);
  } on HandshakeException catch (e) {
    throw NetworkException('TLS el sıkışması başarısız: ${uri.host}', cause: e);
  } on TimeoutException catch (e) {
    throw NetworkException('Sunucu yanıt vermedi: ${uri.host}', cause: e);
  } on HttpException catch (e) {
    throw NetworkException('HTTP hatası: ${e.message}', cause: e);
  } finally {
    client.close(force: true);
  }
}

/// `Content-Range: bytes 0-0/1234` içinden toplam boyutu okur.
int? parseContentRangeTotal(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^\s*bytes\s+\S+/(\d+)\s*$').firstMatch(value);
  return match == null ? null : int.tryParse(match[1]!);
}

/// `Content-Range` içinden aralık başlangıcını okur.
int? parseContentRangeStart(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^\s*bytes\s+(\d+)-').firstMatch(value);
  return match == null ? null : int.tryParse(match[1]!);
}

class _Sent {
  _Sent(this.response, this.finalUri);
  final HttpClientResponse response;
  final Uri finalUri;
}

Future<_Sent> _send(
  HttpClient client,
  String method,
  Uri uri,
  Map<String, String> headers,
  Duration timeout,
) async {
  final request = await client.openUrl(method, uri).timeout(timeout);
  request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
  headers.forEach(request.headers.set);
  final response = await request.close().timeout(timeout);
  return _Sent(response, resolveFinalUri(uri, response));
}

/// Yönlendirme zincirini izleyip son adresi hesaplar.
Uri resolveFinalUri(Uri start, HttpClientResponse response) {
  var current = start;
  for (final redirect in response.redirects) {
    current = current.resolveUri(redirect.location);
  }
  return current;
}

ProbeResult _result(
  Uri original,
  _Sent sent, {
  required int? size,
  required bool acceptsRanges,
}) {
  final headers = sent.response.headers;
  final rawName = fileNameFromContentDisposition(
        headers.value('content-disposition'),
      ) ??
      fileNameFromUri(sent.finalUri) ??
      fileNameFromUri(original) ??
      'download';
  return ProbeResult(
    originalUri: original,
    finalUri: sent.finalUri,
    size: size,
    acceptsRanges: acceptsRanges,
    fileName: sanitizeFileName(rawName),
    etag: headers.value(HttpHeaders.etagHeader),
    lastModified: headers.value(HttpHeaders.lastModifiedHeader),
    contentType: headers.contentType?.mimeType,
  );
}

/// Gövdeyi okumadan bağlantıyı bırakır; 200 yanıtında tüm dosyayı çekmemek için.
Future<void> _discard(HttpClientResponse response) async {
  try {
    final socket = await response.detachSocket();
    socket.destroy();
  } on Object {
    // Soket zaten kapanmış olabilir; yanıtın gövdesine ihtiyacımız yok.
  }
}
