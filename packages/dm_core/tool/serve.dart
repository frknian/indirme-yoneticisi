import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Elle test için Range destekli, hızı sınırlanabilir yerel dosya sunucusu.
///
/// `dart run tool/serve.dart [boyutMiB=50] [port=8099] [baglantiBasinaKiBs=2048]`
/// Android emülatöründen host makineye `http://10.0.2.2:<port>/test.bin` ile erişilir.
Future<void> main(List<String> args) async {
  final sizeMiB = args.isNotEmpty ? int.parse(args[0]) : 50;
  final port = args.length > 1 ? int.parse(args[1]) : 8099;
  final rateKiB = args.length > 2 ? int.parse(args[2]) : 2048;

  final random = Random(1);
  final data = Uint8List(sizeMiB * 1024 * 1024);
  for (var i = 0; i < data.length; i += 4096) {
    data[i] = random.nextInt(256);
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('http://127.0.0.1:$port/test.bin  ($sizeMiB MiB)');
  await for (final request in server) {
    final response = request.response;
    response.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.etagHeader, '"fixed-$sizeMiB"');
    if (request.method == 'HEAD') {
      response.contentLength = data.length;
      await response.close();
      continue;
    }
    var start = 0;
    var end = data.length - 1;
    final match = RegExp(r'bytes=(\d+)-(\d*)')
        .firstMatch(request.headers.value(HttpHeaders.rangeHeader) ?? '');
    if (match != null) {
      start = int.parse(match[1]!);
      if (match[2]!.isNotEmpty) end = min(int.parse(match[2]!), end);
      response.statusCode = HttpStatus.partialContent;
      response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${data.length}',
      );
    }
    response.contentLength = end - start + 1;
    unawaited(_send(response, data, start, end, rateKiB * 1024 ~/ 20));
  }
}

Future<void> _send(
  HttpResponse response,
  Uint8List data,
  int start,
  int end,
  int perTick,
) async {
  try {
    var cursor = start;
    while (cursor <= end) {
      final next = min(cursor + perTick, end + 1);
      response.add(Uint8List.sublistView(data, cursor, next));
      await response.flush();
      cursor = next;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await response.close();
  } on Object {
    // İstemci bağlantıyı kesti (duraklatma); beklenen durum.
  }
}
