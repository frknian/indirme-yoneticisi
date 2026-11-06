import 'dart:convert';
import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:test/test.dart';

void main() {
  final token = CaptureServer.generateToken();
  late CaptureServer server;
  final received = <CaptureRequest>[];

  Future<(int, String)> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    String? body,
    bool withToken = true,
    String? hostOverride,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${server.boundPort}$path'),
      );
      if (withToken) request.headers.set('X-DM-Token', token);
      if (hostOverride != null) request.headers.set('Host', hostOverride);
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(body);
      }
      final response = await request.close();
      return (
        response.statusCode,
        await response.transform(utf8.decoder).join()
      );
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    received.clear();
    server = CaptureServer(token: token, port: 0, onRequest: received.add);
    await server.start();
  });

  tearDown(() => server.stop());

  final valid = jsonEncode({
    'url': 'https://example.com/a.zip',
    'fileName': 'a.zip',
    'referer': 'https://example.com/',
  });

  test('geçerli isteği kabul eder', () async {
    final (status, _) = await send('POST', '/download', body: valid);
    expect(status, HttpStatus.accepted);
    expect(received.single.url.toString(), 'https://example.com/a.zip');
    expect(received.single.fileName, 'a.zip');
    expect(received.single.referer, 'https://example.com/');
  });

  test('eklenti kökeninden gelen isteği kabul eder', () async {
    final (status, _) = await send('POST', '/download',
        headers: {'Origin': 'chrome-extension://abcdefg'}, body: valid);
    expect(status, HttpStatus.accepted);
  });

  test('anahtarsız istek reddedilir', () async {
    final (status, _) =
        await send('POST', '/download', body: valid, withToken: false);
    expect(status, HttpStatus.unauthorized);
    expect(received, isEmpty);
  });

  test('yanlış anahtar reddedilir', () async {
    final (status, _) = await send('POST', '/download',
        body: valid, withToken: false, headers: {'X-DM-Token': 'f' * 64});
    expect(status, HttpStatus.unauthorized);
  });

  test('web sitesi kökeni, anahtar doğru olsa bile reddedilir', () async {
    final (status, _) = await send('POST', '/download',
        headers: {'Origin': 'https://evil.example'}, body: valid);
    expect(status, HttpStatus.forbidden);
    expect(received, isEmpty);
  });

  test('web sitesi ön uçuş (preflight) isteğine CORS izni verilmez', () async {
    final (status, _) = await send('OPTIONS', '/download',
        withToken: false, headers: {'Origin': 'https://evil.example'});
    expect(status, HttpStatus.forbidden);
  });

  test('DNS rebinding: yabancı Host reddedilir', () async {
    final (status, _) = await send('POST', '/download',
        body: valid, hostOverride: 'evil.example:38765');
    expect(status, HttpStatus.forbidden);
    expect(received, isEmpty);
  });

  test('magnet kabul edilir', () async {
    final (status, _) = await send(
      'POST',
      '/download',
      body: jsonEncode({'url': 'magnet:?xt=urn:btih:abc'}),
    );
    expect(status, HttpStatus.accepted);
    expect(received.single.url.isScheme('magnet'), isTrue);
  });

  test('http/https dışı adres reddedilir', () async {
    for (final url in [
      'file:///etc/passwd',
      'ftp://x/y',
      'javascript:alert(1)'
    ]) {
      final (status, _) =
          await send('POST', '/download', body: jsonEncode({'url': url}));
      expect(status, HttpStatus.badRequest, reason: url);
    }
    expect(received, isEmpty);
  });

  test('bozuk JSON ve aşırı büyük gövde reddedilir', () async {
    final (bad, _) = await send('POST', '/download', body: '{bozuk');
    expect(bad, HttpStatus.badRequest);
    final (noUrl, _) = await send('POST', '/download', body: '{"x":1}');
    expect(noUrl, HttpStatus.badRequest);
    final (big, _) = await send('POST', '/download',
        body: jsonEncode({'url': 'https://a/${'x' * 70000}'}));
    expect(big, HttpStatus.requestEntityTooLarge);
  });

  test('referer yalnızca http(s) olabilir', () async {
    await send('POST', '/download',
        body: jsonEncode({'url': 'https://a/b', 'referer': 'javascript:x'}));
    expect(received.single.referer, isNull);
  });

  test('ping yalnızca anahtarla yanıt verir', () async {
    expect((await send('GET', '/ping')).$1, HttpStatus.ok);
    expect((await send('GET', '/ping', withToken: false)).$1,
        HttpStatus.unauthorized);
  });

  test('dış arabirimden erişilemez, yalnızca loopback dinler', () async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final external = interfaces
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback)
        .toList();
    for (final address in external) {
      await expectLater(
        Socket.connect(
          address,
          server.boundPort!,
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<SocketException>()),
        reason: address.address,
      );
    }
    final local = await Socket.connect(
      InternetAddress.loopbackIPv4,
      server.boundPort!,
    );
    local.destroy();
  });

  test('port doluysa açık tipli hata verir', () async {
    final other = CaptureServer(
      token: token,
      port: server.boundPort!,
      onRequest: (_) {},
    );
    expect(other.start(), throwsA(isA<CaptureServerException>()));
  });

  test('kısa anahtar kabul edilmez', () {
    expect(
      () => CaptureServer(token: 'kisa', onRequest: (_) {}),
      throwsArgumentError,
    );
  });
}
