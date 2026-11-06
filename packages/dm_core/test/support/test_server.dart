import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Bir isteği özel yanıtlamak için kanca; true dönerse sunucu devam etmez.
typedef Intercept = Future<bool> Function(HttpRequest request, int getIndex);

/// Range destekli, davranışı ayarlanabilir yerel test sunucusu.
class TestServer {
  TestServer(
    this.data, {
    this.supportRanges = true,
    this.advertiseRanges = true,
    this.allowHead = true,
    this.sendContentLength = true,
    this.ignoreRangeHeader = false,
    this.etag = '"v1"',
    this.lastModified,
    this.contentDisposition,
    this.chunkSize = 16 * 1024,
    this.chunkDelay = Duration.zero,
    this.intercept,
  });

  Uint8List data;
  bool supportRanges;
  bool advertiseRanges;
  bool allowHead;
  bool sendContentLength;

  /// HEAD'de Range var der ama GET'te 200 döner.
  bool ignoreRangeHeader;
  String? etag;
  String? lastModified;
  String? contentDisposition;
  int chunkSize;
  Duration chunkDelay;
  Intercept? intercept;

  /// Her GET isteğinin istediği Range başlığı (null: tüm dosya).
  final List<String?> getRanges = [];
  int headCount = 0;
  int bytesServed = 0;
  int maxConcurrentGets = 0;
  int _activeGets = 0;
  late HttpServer _server;

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/files/data.bin');
  Uri path(String p) => Uri.parse('http://127.0.0.1:${_server.port}$p');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.uri.path == '/redirect') {
        await response.redirect(uri, status: HttpStatus.found);
        return;
      }
      if (request.method == 'HEAD') {
        headCount++;
        if (!allowHead) {
          response.statusCode = HttpStatus.methodNotAllowed;
          await response.close();
          return;
        }
        _commonHeaders(response);
        if (sendContentLength) response.contentLength = data.length;
        await response.close();
        return;
      }

      final index = getRanges.length;
      getRanges.add(request.headers.value(HttpHeaders.rangeHeader));
      _activeGets++;
      maxConcurrentGets = max(maxConcurrentGets, _activeGets);
      try {
        if (intercept != null && await intercept!(request, index)) return;
        await _serveBody(request);
      } finally {
        _activeGets--;
      }
    } on Object {
      // İstemci koptu; test bunu bekliyor olabilir.
      try {
        await response.close();
      } on Object {
        // Yanıt zaten kapalı.
      }
    }
  }

  void _commonHeaders(HttpResponse response) {
    if (advertiseRanges && supportRanges) {
      response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    }
    if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag!);
    if (lastModified != null) {
      response.headers.set(HttpHeaders.lastModifiedHeader, lastModified!);
    }
    if (contentDisposition != null) {
      response.headers.set('content-disposition', contentDisposition!);
    }
  }

  Future<void> _serveBody(HttpRequest request) async {
    final response = request.response;
    _commonHeaders(response);
    var start = 0;
    var end = data.length - 1;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    final ifRange = request.headers.value(HttpHeaders.ifRangeHeader);
    final honorIfRange =
        ifRange == null || ifRange == etag || ifRange == lastModified;
    if (supportRanges && !ignoreRangeHeader && range != null && honorIfRange) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      start = int.parse(match[1]!);
      if (match[2]!.isNotEmpty) end = min(int.parse(match[2]!), end);
      if (start >= data.length) {
        response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await response.close();
        return;
      }
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${data.length}',
      );
    }
    if (sendContentLength) response.contentLength = end - start + 1;
    await sendRange(response, start, end);
    await response.close();
  }

  Future<void> sendRange(HttpResponse response, int start, int end) async {
    var cursor = start;
    while (cursor <= end) {
      final next = min(cursor + chunkSize, end + 1);
      response.add(Uint8List.sublistView(data, cursor, next));
      await response.flush();
      bytesServed += next - cursor;
      cursor = next;
      if (chunkDelay > Duration.zero) await Future<void>.delayed(chunkDelay);
    }
  }

  /// Yanıtın yarısını gönderip soketi keser.
  Future<void> serveThenDrop(HttpRequest request, int bytes) async {
    final response = request.response;
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = data.length - 1;
    if (range != null) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      start = int.parse(match[1]!);
      if (match[2]!.isNotEmpty) end = int.parse(match[2]!);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${data.length}',
      );
    }
    _commonHeaders(response);
    response.contentLength = end - start + 1;
    await sendRange(response, start, min(start + bytes - 1, end));
    final socket = await response.detachSocket(writeHeaders: false);
    socket.destroy();
  }
}

/// Tekrarlanabilir rastgele veri.
Uint8List randomBytes(int length, {int seed = 42}) {
  final random = Random(seed);
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

extension TestServerRange on TestServer {
  /// Kanca içinden normal Range yanıtı gönderir.
  Future<void> sendRangeFor(HttpRequest request) async {
    final response = request.response;
    final match = RegExp(r'bytes=(\d+)-(\d*)')
        .firstMatch(request.headers.value(HttpHeaders.rangeHeader)!)!;
    final start = int.parse(match[1]!);
    final end = match[2]!.isEmpty ? data.length - 1 : int.parse(match[2]!);
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(
        HttpHeaders.contentRangeHeader, 'bytes $start-$end/${data.length}');
    if (etag != null) response.headers.set(HttpHeaders.etagHeader, etag!);
    response.contentLength = end - start + 1;
    chunkDelay = const Duration(milliseconds: 2);
    await sendRange(response, start, end);
    await response.close();
  }
}
