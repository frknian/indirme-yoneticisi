// Ağa çıkmadan yt-dlp davranışını taklit eden program; testler derleyip kullanır.
// Davranış adresin yolundan seçilir: /ok, /twostream, /drm, /unsupported, /slow,
// /noentries, /playlist. Aldığı argümanları kendi yanına yazar.
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  File('${Platform.resolvedExecutable}.args')
      .writeAsStringSync(jsonEncode(args));
  if (args.contains('--version')) {
    stdout.writeln('2099.01.01');
    return;
  }
  final url = Uri.parse(args.last);
  if (args.contains('-J')) {
    if (url.path == '/playlist' && args.contains('--yes-playlist')) {
      stdout.write(jsonEncode({
        '_type': 'playlist',
        'title': 'Örnek/Liste',
        'entries': [
          {'url': 'http://fake.invalid/ok?a', 'title': 'Bir'},
          {'url': 'http://fake.invalid/ok?b', 'title': 'İki'},
          {'url': 'not a url', 'title': 'Bozuk'},
        ],
      }));
    } else if (url.path == '/unsupported') {
      stderr.writeln('ERROR: Unsupported URL: $url');
      exit(1);
    } else if (url.path == '/qualities') {
      stdout.write(jsonEncode({
        '_type': 'video',
        'title': 'Kaliteli',
        'duration': 100,
        'formats': [
          {'vcodec': 'none', 'acodec': 'none', 'ext': 'mhtml', 'height': 90},
          {
            'vcodec': 'none',
            'acodec': 'opus',
            'ext': 'webm',
            'abr': 160,
            'filesize': 9
          },
          {
            'vcodec': 'none',
            'acodec': 'mp4a.40.2',
            'ext': 'm4a',
            'abr': 128,
            'filesize': 1000
          },
          {
            'vcodec': 'av01.0',
            'acodec': 'none',
            'height': 2160,
            'width': 3840,
            'filesize': 90000
          },
          {
            'vcodec': 'vp9',
            'acodec': 'none',
            'height': 1080,
            'width': 1920,
            'filesize': 7000
          },
          {
            'vcodec': 'avc1.64',
            'acodec': 'none',
            'protocol': 'm3u8_native',
            'height': 1080,
            'width': 1920,
            'tbr': 900000,
          },
          {
            'vcodec': 'avc1.64',
            'acodec': 'none',
            'height': 1080,
            'width': 1920,
            'filesize': 5000
          },
          {
            'vcodec': 'avc1.4d',
            'acodec': 'mp4a.40.2',
            'height': 720,
            'width': 1280,
            'tbr': 8
          },
          {'vcodec': 'avc1.4d', 'acodec': 'none', 'height': 1280, 'width': 480},
          {'acodec': 'none', 'ext': 'mp4'},
        ],
      }));
    } else {
      stdout.write(jsonEncode({'_type': 'video', 'title': 'Tek', 'id': 'x'}));
    }
    return;
  }

  String pathArg(String prefix) =>
      args.where((a) => a.startsWith(prefix)).first.substring(prefix.length);
  final home = pathArg('home:');
  final temp = pathArg('temp:');
  final isMp3 = args.contains('-x');
  final id = url.query.isEmpty ? 'id' : url.query;
  final name = 'Başlık [$id].${isMp3 ? 'mp3' : 'mp4'}';
  stdout.writeln('DMTITLE Başlık');

  switch (url.path) {
    case '/drm':
      stderr.writeln('ERROR: [Fake] x: This video is DRM protected');
      exit(1);
    case '/unsupported':
      stderr.writeln('ERROR: Unsupported URL: $url');
      exit(1);
    case '/signin':
      stderr.writeln('ERROR: [Fake] x: Sign in to confirm your age');
      exit(1);
    case '/nofile':
      exit(0);
  }

  final part = File('$temp/$name.part');
  final resumed = part.existsSync();
  stdout.writeln('RESUMED $resumed');
  part.writeAsStringSync('yarım', mode: FileMode.append);

  if (url.path == '/slow') {
    File('${Platform.resolvedExecutable}.resumed')
        .writeAsStringSync('$resumed');
    for (var i = 1; i < 2000; i++) {
      stdout.writeln('DM downloading ${i * 1000} 2000000 NA 1000.5 $i');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return;
  }

  stdout.writeln('DM downloading 500 1000 NA 250.5 2');
  if (url.path == '/twostream') {
    stdout.writeln('DM finished 1000 1000 NA NA NA');
    stdout.writeln('DM downloading 100 400 NA NA NA');
    stdout.writeln('DM finished 400 400 NA NA NA');
  } else {
    stdout.writeln('DM downloading 1000 1000 NA NA NA');
    stdout.writeln('DM finished 1000 1000 NA NA NA');
  }
  stdout.writeln('DMPP started ${isMp3 ? 'ExtractAudio' : 'VideoConvertor'}');
  stdout.writeln('DMPP finished ${isMp3 ? 'ExtractAudio' : 'VideoConvertor'}');
  stdout.writeln('DMPP started MoveFiles');
  final finalPath = '$home${Platform.pathSeparator}$name';
  File(finalPath).writeAsStringSync('veri');
  part.deleteSync();
  stdout.writeln('DMFILE $finalPath');
  await stdout.flush();
}
