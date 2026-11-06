import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Basit bencode kodlayıcı; anahtarlar kurala uygun sıralanır.
List<int> bencodeValue(Object value) {
  if (value is int) return ascii.encode('i${value}e');
  if (value is String) return bencodeValue(utf8.encode(value));
  if (value is List<int>) {
    return [...ascii.encode('${value.length}:'), ...value];
  }
  if (value is List) {
    return [0x6c, ...value.expand((e) => bencodeValue(e as Object)), 0x65];
  }
  if (value is Map<String, Object>) {
    final keys = value.keys.toList()..sort();
    return [
      0x64,
      for (final key in keys) ...[
        ...bencodeValue(key),
        ...bencodeValue(value[key]!),
      ],
      0x65,
    ];
  }
  throw ArgumentError(value);
}

class FakeTorrent {
  FakeTorrent(
    this.bytes,
    this.infoHash,
    this.data,
    this.pieceLength,
    this.infoBytes,
  );

  /// Bencode kodlu `info` sözlüğü (ut_metadata ile gönderilir).
  final List<int> infoBytes;

  /// `.torrent` dosyasının içeriği.
  final Uint8List bytes;
  final Uint8List infoHash;

  /// Tüm dosyaların birleşik içeriği.
  final Uint8List data;
  final int pieceLength;

  String get infoHashHex =>
      infoHash.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Tek veya çok dosyalı torrent üretir. [files] verilirse `path/parça` listesi anahtardır.
FakeTorrent buildTorrent({
  required String name,
  required Uri announce,
  Uint8List? single,
  Map<List<String>, Uint8List>? files,
  int pieceLength = 16384,
}) {
  final data =
      single ?? Uint8List.fromList(files!.values.expand((e) => e).toList());
  final pieces = <int>[];
  for (var i = 0; i < data.length; i += pieceLength) {
    final end = i + pieceLength < data.length ? i + pieceLength : data.length;
    pieces.addAll(sha1.convert(Uint8List.sublistView(data, i, end)).bytes);
  }
  final info = <String, Object>{
    'name': name,
    'piece length': pieceLength,
    'pieces': pieces,
    if (single != null) 'length': single.length,
    if (files != null)
      'files': [
        for (final e in files.entries)
          <String, Object>{'length': e.value.length, 'path': e.key},
      ],
  };
  final bytes = bencodeValue(<String, Object>{
    'announce': announce.toString(),
    'info': info,
  });
  final hash = sha1.convert(bencodeValue(info)).bytes;
  return FakeTorrent(
    Uint8List.fromList(bytes),
    Uint8List.fromList(hash),
    data,
    pieceLength,
    bencodeValue(info),
  );
}

/// Tek eşi bildiren yerel izleyici.
class FakeTracker {
  late HttpServer _server;
  int peerPort = 0;
  int announces = 0;

  Uri get announce => Uri.parse('http://127.0.0.1:${_server.port}/announce');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      announces++;
      final peers = [127, 0, 0, 1, peerPort >> 8, peerPort & 0xff];
      request.response.add(bencodeValue(<String, Object>{
        'interval': 60,
        'peers': peers,
      }));
      await request.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// BitTorrent kablo protokolünün gereken kısmını konuşan yerel kaynak.
class FakeSeeder {
  FakeSeeder(this.torrent, {this.delay = Duration.zero});

  final FakeTorrent torrent;

  /// Her blok yanıtından önceki bekleme; duraklatma testleri için.
  Duration delay;
  late ServerSocket _server;
  final List<Socket> _sockets = [];
  int blocksServed = 0;
  int metadataRequests = 0;
  final List<int> requestedPieces = [];

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_serve);
  }

  Future<void> stop() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close();
  }

  void _serve(Socket socket) {
    _sockets.add(socket);
    unawaited(socket.done.catchError((Object _) {}));
    var buffer = <int>[];
    var handshaken = false;
    var busy = Future<void>.value();
    int? remoteMetadataId;
    final pieceCount = (torrent.data.length / torrent.pieceLength).ceil();
    socket.listen(
      (chunk) {
        buffer.addAll(chunk);
        if (!handshaken) {
          if (buffer.length < 68) return;
          buffer = buffer.sublist(68);
          handshaken = true;
          socket.add([
            19,
            ...ascii.encode('BitTorrent protocol'),
            // Bit 20: uzantı protokolü (BEP 10).
            0, 0, 0, 0, 0, 0x10, 0, 0,
            ...torrent.infoHash,
            ...ascii.encode('-FS0001-000000000000'),
          ]);
          final bitfield = List<int>.filled((pieceCount + 7) ~/ 8, 0);
          for (var i = 0; i < pieceCount; i++) {
            bitfield[i ~/ 8] |= 0x80 >> (i % 8);
          }
          _sendMessage(socket, 5, bitfield);
          // Karşı taraf kimliğini bilerek farklı seçiyoruz: 7, eşleme hatasını yakalar.
          _sendMessage(socket, 20, [
            0,
            ...bencodeValue(<String, Object>{
              'm': <String, Object>{'ut_metadata': 7},
              'metadata_size': torrent.infoBytes.length,
            }),
          ]);
        }
        while (buffer.length >= 4) {
          final length = ByteData.sublistView(
            Uint8List.fromList(buffer.sublist(0, 4)),
          ).getUint32(0);
          if (buffer.length < 4 + length) break;
          final body = buffer.sublist(4, 4 + length);
          buffer = buffer.sublist(4 + length);
          if (body.isEmpty) continue;
          if (body[0] == 2) {
            _sendMessage(socket, 1, const []); // interested -> unchoke
          }
          if (body[0] == 20) {
            _handleExtended(socket, body, (id) => remoteMetadataId = id,
                () => remoteMetadataId);
          }
          if (body[0] == 6) {
            final view = ByteData.sublistView(Uint8List.fromList(body));
            final index = view.getUint32(1);
            final begin = view.getUint32(5);
            final size = view.getUint32(9);
            busy = busy.then((_) async {
              if (delay > Duration.zero) {
                await Future<void>.delayed(delay);
              }
              _sendPiece(socket, index, begin, size);
            });
          }
        }
      },
      onError: (_) {},
      onDone: socket.destroy,
      cancelOnError: true,
    );
  }

  void _handleExtended(
    Socket socket,
    List<int> body,
    void Function(int) setRemote,
    int? Function() getRemote,
  ) {
    final id = body[1];
    final text = latin1.decode(body.sublist(2));
    if (id == 0) {
      final match = RegExp(r'ut_metadatai(\d+)e').firstMatch(text);
      if (match != null) setRemote(int.parse(match[1]!));
      return;
    }
    if (id != 7) return; // Bizim bildirdiğimiz ut_metadata kimliği.
    final piece = RegExp(r'5:piecei(\d+)e').firstMatch(text);
    final remote = getRemote();
    if (piece == null || remote == null) return;
    final index = int.parse(piece[1]!);
    const block = 16384;
    final start = index * block;
    final end = start + block < torrent.infoBytes.length
        ? start + block
        : torrent.infoBytes.length;
    metadataRequests++;
    _sendMessage(socket, 20, [
      remote,
      ...bencodeValue(<String, Object>{
        'msg_type': 1,
        'piece': index,
        'total_size': torrent.infoBytes.length,
      }),
      ...torrent.infoBytes.sublist(start, end),
    ]);
  }

  void _sendMessage(Socket socket, int id, List<int> payload) {
    final header = ByteData(5)
      ..setUint32(0, payload.length + 1)
      ..setUint8(4, id);
    try {
      socket
        ..add(header.buffer.asUint8List())
        ..add(payload);
    } on Object {
      // İstemci bağlantıyı kapattı.
    }
  }

  void _sendPiece(Socket socket, int index, int begin, int size) {
    requestedPieces.add(index);
    blocksServed++;
    final offset = index * torrent.pieceLength + begin;
    final head = ByteData(8)
      ..setUint32(0, index)
      ..setUint32(4, begin);
    _sendMessage(socket, 7, [
      ...head.buffer.asUint8List(),
      ...Uint8List.sublistView(torrent.data, offset, offset + size),
    ]);
  }
}
