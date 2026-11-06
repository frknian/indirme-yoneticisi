import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'exceptions.dart';

/// Çıkış biçimi.
enum MediaFormat { mp4, mp3 }

/// Video veya ses indirme seçenekleri.
class MediaOptions {
  const MediaOptions({this.format = MediaFormat.mp4, this.maxHeight});

  factory MediaOptions.fromJson(Map<String, dynamic> json) => MediaOptions(
        format:
            MediaFormat.values.asNameMap()[json['format']] ?? MediaFormat.mp4,
        maxHeight: json['maxHeight'] as int?,
      );

  final MediaFormat format;

  /// Video kalitesi sınırı, görüntünün kısa kenarı (örn. 720); null en iyi kalite demektir.
  final int? maxHeight;

  Map<String, dynamic> toJson() => {
        'format': format.name,
        'maxHeight': maxHeight,
      };
}

/// yt-dlp masaüstü dışında çalışmaz.
bool get isMediaSupported =>
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// Bu adres büyük olasılıkla dosya değil video sayfası mı?
bool isLikelyMediaUrl(Uri uri) {
  if (!(uri.isScheme('http') || uri.isScheme('https'))) return false;
  if (uri.path.toLowerCase().endsWith('.m3u8') ||
      uri.path.toLowerCase().endsWith('.mpd')) {
    return true;
  }
  final host = uri.host.toLowerCase().replaceFirst(RegExp(r'^(www|m)\.'), '');
  const hosts = {
    'youtube.com',
    'youtu.be',
    'music.youtube.com',
    'vimeo.com',
    'dailymotion.com',
    'twitch.tv',
    'soundcloud.com',
    'tiktok.com',
    'instagram.com',
    'facebook.com',
    'x.com',
    'twitter.com',
    'bilibili.com',
    'rumble.com',
  };
  return hosts.contains(host);
}

/// DRM kullanan ücretli platformlar. Bu sitelerde genel yöntem yalnızca tanıtım fragmanını
/// bulur; kullanıcı filmi indirdiğini sanmasın diye baştan açık hata verilir.
bool isDrmPlatformUrl(Uri uri) {
  final host = uri.host.toLowerCase();
  const domains = [
    'netflix.com',
    'disneyplus.com',
    'primevideo.com',
    'hulu.com',
    'max.com',
    'hbomax.com',
    'tv.apple.com',
    'paramountplus.com',
    'mubi.com',
    'blutv.com',
    'exxen.com',
    'gain.tv',
  ];
  return domains.any((d) => host == d || host.endsWith('.$d'));
}

void rejectDrmPlatform(Uri uri) {
  if (isDrmPlatformUrl(uri)) {
    throw MediaDrmException(
      '${uri.host} içerikleri DRM ile korunuyor ve indirilemez.',
    );
  }
}

/// Bulunan araçların yolları.
class MediaToolPaths {
  const MediaToolPaths({required this.ytDlp, required this.ffmpeg});
  final String? ytDlp;
  final String? ffmpeg;
  bool get isComplete => ytDlp != null && ffmpeg != null;
}

/// Masaüstünden açılan uygulamalar kabuğun PATH'ini görmez; paket yöneticilerinin
/// klasörlerine bu yüzden ayrıca bakılır.
List<String> mediaToolSearchDirs() {
  final env = Platform.environment;
  final path = env['PATH'] ?? env['Path'] ?? '';
  return [
    ...path.split(Platform.isWindows ? ';' : ':').where((e) => e.isNotEmpty),
    if (Platform.isMacOS) ...['/opt/homebrew/bin', '/usr/local/bin'],
    if (Platform.isLinux) ...[
      '/usr/bin',
      '/usr/local/bin',
      '/snap/bin',
      if (env['HOME'] != null) p.join(env['HOME']!, '.local', 'bin'),
    ],
    if (Platform.isWindows && env['LOCALAPPDATA'] != null)
      p.join(env['LOCALAPPDATA']!, 'Microsoft', 'WinGet', 'Links'),
    if (Platform.isWindows && env['ProgramFiles'] != null)
      p.join(env['ProgramFiles']!, 'WinGet', 'Links'),
    if (Platform.isWindows) ...[
      if (env['LOCALAPPDATA'] != null)
        ...wingetFfmpegDirs(
          p.join(env['LOCALAPPDATA']!, 'Microsoft', 'WinGet', 'Packages'),
        ),
      if (env['ProgramFiles'] != null)
        ...wingetFfmpegDirs(p.join(env['ProgramFiles']!, 'WinGet', 'Packages')),
    ],
  ];
}

/// winget, ffmpeg gibi çok dosyalı paketleri `Links` yerine kendi klasörüne kurar
/// ve yalnızca PATH'e ekler; o PATH zaten açık olan uygulamaya ulaşmaz.
List<String> wingetFfmpegDirs(String packagesRoot) {
  final root = Directory(packagesRoot);
  if (!root.existsSync()) return const [];
  final dirs = <String>[];
  try {
    for (final package in root.listSync().whereType<Directory>()) {
      if (!p.basename(package.path).toLowerCase().contains('ffmpeg')) continue;
      dirs.add(package.path);
      for (final build in package.listSync().whereType<Directory>()) {
        dirs.add(p.join(build.path, 'bin'));
      }
    }
  } on FileSystemException {
    // Okunamayan klasör, aracın bulunamadığı anlamına gelir; hata kurulum ipucuyla bildirilir.
  }
  return dirs;
}

String? _findTool(String name, List<String> dirs) {
  final file = Platform.isWindows ? '$name.exe' : name;
  for (final dir in dirs) {
    final candidate = p.join(dir, file);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}

/// `yt-dlp` ve `ffmpeg`i arar. Açıkça verilen yollar önceliklidir.
MediaToolPaths locateMediaTools({
  String? ytDlpPath,
  String? ffmpegPath,
  List<String>? searchDirs,
}) {
  final dirs = searchDirs ?? mediaToolSearchDirs();
  return MediaToolPaths(
    ytDlp: ytDlpPath ?? _findTool('yt-dlp', dirs),
    ffmpeg: ffmpegPath ?? _findTool('ffmpeg', dirs),
  );
}

/// yt-dlp sürümü; çalıştırılamazsa null.
Future<String?> mediaToolVersion(String ytDlp) async {
  try {
    final result = await Process.run(ytDlp, ['--version']);
    if (result.exitCode != 0) return null;
    return (result.stdout as String).trim();
  } on ProcessException {
    return null;
  }
}

/// Eksik araç için kullanıcıya gösterilecek kurulum komutu.
String mediaInstallHint() {
  if (Platform.isWindows) {
    return 'winget install --id yt-dlp.yt-dlp -e';
  }
  if (Platform.isMacOS) return 'brew install yt-dlp ffmpeg';
  return 'Paket yöneticinizle yt-dlp ve ffmpeg kurun';
}

void requireMediaTools(MediaToolPaths tools) {
  final missing = [
    if (tools.ytDlp == null) 'yt-dlp',
    if (tools.ffmpeg == null) 'ffmpeg',
  ];
  if (missing.isEmpty) return;
  throw MediaToolMissingException(
    '${missing.join(' ve ')} bulunamadı. Kurmak için: ${mediaInstallHint()}',
  );
}

const String _progressTemplate = 'download:DM %(progress.status)s '
    '%(progress.downloaded_bytes)s %(progress.total_bytes)s '
    '%(progress.total_bytes_estimate)s %(progress.speed)s %(progress.eta)s';
const String _postTemplate =
    'postprocess:DMPP %(progress.status)s %(progress.postprocessor)s';

/// Çalıştırma ortamı: Windows'ta çıktı kodlaması Türkçe karakterleri bozmasın.
const Map<String, String> mediaProcessEnvironment = {
  'PYTHONIOENCODING': 'utf-8',
  'PYTHONUTF8': '1',
};

/// İndirme argümanları. Adres `--` sonrasında verilir: `-` ile başlayan adres seçenek
/// olarak yorumlanamaz. `--no-config` kullanıcının yt-dlp ayarlarının (ör. `--exec`)
/// uygulamanın davranışını değiştirmesini önler.
List<String> buildMediaDownloadArgs({
  required Uri url,
  required MediaOptions options,
  required String homeDir,
  required String tempDir,
  required String? ffmpeg,
  String? proxy,
  int maxBytesPerSecond = 0,
  int connectionTimeoutSeconds = 20,
  int retries = 8,
}) {
  final height = options.maxHeight;
  return [
    '--no-config',
    '--no-warnings',
    '--no-playlist',
    // Birden çok video içeren sayfada yalnızca ilki: aksi halde adres başına tek
    // dosya varsayımı bozulur ve fazladan dosya iner.
    '--playlist-items',
    '1',
    '--newline',
    '--no-mtime',
    '--windows-filenames',
    '--encoding',
    'utf-8',
    '--continue',
    '--socket-timeout',
    '$connectionTimeoutSeconds',
    '--retries',
    '$retries',
    if (proxy != null) ...['--proxy', 'http://$proxy'],
    if (maxBytesPerSecond > 0) ...['--limit-rate', '$maxBytesPerSecond'],
    if (ffmpeg != null) ...['--ffmpeg-location', ffmpeg],
    '-P',
    'home:$homeDir',
    '-P',
    'temp:$tempDir',
    '-o',
    '%(title).150B [%(id)s].%(ext)s',
    if (options.format == MediaFormat.mp3) ...[
      '-x',
      '--audio-format',
      'mp3',
      '--audio-quality',
      '0',
    ] else ...[
      // Önce seçilen kalite; aynı kalitede H.264 ve AAC tercih edilir. vcodec öne alınırsa
      // yalnızca VP9/AV1 olan 4K seçimi sessizce H.264 1080p'ye düşer.
      '-S',
      '${height == null ? 'res' : 'res:$height'},vcodec:h264,acodec:m4a',
      '--merge-output-format',
      'mp4',
      '--recode-video',
      'mp4',
    ],
    '--progress-template',
    _progressTemplate,
    '--progress-template',
    _postTemplate,
    '--print',
    'before_dl:DMTITLE %(title)s',
    '--print',
    'after_move:DMFILE %(filepath)s',
    '--no-simulate',
    '--',
    url.toString(),
  ];
}

/// yt-dlp'nin bir çıktı satırı.
sealed class MediaEvent {
  const MediaEvent();
}

final class MediaProgressEvent extends MediaEvent {
  const MediaProgressEvent({
    required this.finished,
    required this.downloaded,
    required this.total,
    required this.bytesPerSecond,
    required this.etaSeconds,
  });
  final bool finished;
  final int? downloaded;
  final int? total;
  final double? bytesPerSecond;
  final int? etaSeconds;
}

final class MediaConvertingEvent extends MediaEvent {
  const MediaConvertingEvent();
}

final class MediaTitleEvent extends MediaEvent {
  const MediaTitleEvent(this.title);
  final String title;
}

final class MediaFileEvent extends MediaEvent {
  const MediaFileEvent(this.path);
  final String path;
}

/// Satırı çözer; tanınmayan satırda null döner.
MediaEvent? parseMediaLine(String line) {
  if (line.startsWith('DMTITLE ')) return MediaTitleEvent(line.substring(8));
  if (line.startsWith('DMFILE ')) return MediaFileEvent(line.substring(7));
  if (line.startsWith('DMPP ')) {
    final parts = line.split(' ');
    // Taşıma dönüştürme değildir; çok kısa sürer.
    if (parts.length >= 3 && parts[1] == 'started' && parts[2] != 'MoveFiles') {
      return const MediaConvertingEvent();
    }
    return null;
  }
  if (line.startsWith('DM ')) {
    final parts = line.split(' ');
    if (parts.length < 7) return null;
    num? value(String text) => num.tryParse(text);
    return MediaProgressEvent(
      finished: parts[1] == 'finished',
      downloaded: value(parts[2])?.toInt(),
      total: (value(parts[3]) ?? value(parts[4]))?.toInt(),
      bytesPerSecond: value(parts[5])?.toDouble(),
      etaSeconds: value(parts[6])?.toInt(),
    );
  }
  return null;
}

/// Hata çıktısını açık tipe çevirir.
DownloadException classifyMediaError(String stderr, int exitCode) {
  final lines = const LineSplitter()
      .convert(stderr)
      .where((line) => line.startsWith('ERROR:'))
      .toList();
  final text = lines.isEmpty ? stderr.trim() : lines.last;
  final lower = text.toLowerCase();
  if (lower.contains('drm')) {
    return const MediaDrmException(
      'Bu içerik DRM ile korunuyor ve indirilemez.',
    );
  }
  if (lower.contains('unsupported url')) {
    return const MediaDownloadException(
      'Bu site desteklenmiyor veya adreste video bulunamadı.',
    );
  }
  if (lower.contains('sign in') ||
      lower.contains('login') ||
      lower.contains('log in')) {
    return const MediaDownloadException(
      'Bu video oturum açmayı gerektiriyor; oturum bilgisi aktarılmaz.',
    );
  }
  final clean = text.replaceFirst(RegExp(r'^ERROR:\s*'), '');
  return MediaDownloadException(
    clean.isEmpty ? 'yt-dlp başarısız oldu (çıkış kodu $exitCode).' : clean,
  );
}

/// Bir video veya oynatma listesi hakkındaki bilgi.
/// Bir videonun gerçekten sunduğu kalite.
class MediaQuality {
  const MediaQuality({required this.height, this.width, this.estimatedBytes});

  /// Görüntünün kısa kenarı; [MediaOptions.maxHeight] ile aynı birimde.
  final int height;

  /// Görüntünün uzun kenarı; bilinmiyorsa null.
  final int? width;

  /// Bilinen adı. Geniş ekran bir film 1920×804 olsa da 1080p kalitesindedir; kısa kenar
  /// tek başına kullanılırsa listede "804p" görünürdü.
  int get nominalHeight {
    final long = width;
    if (long == null || long * 9 <= height * 16) return height;
    final expected = long * 9 / 16;
    const standard = [144, 240, 360, 480, 720, 1080, 1440, 2160, 4320];
    return standard.firstWhere(
      (h) => h >= expected * 0.98,
      orElse: () => expected.round(),
    );
  }

  /// Örn. "1080p" veya geniş ekranda "1080p (1920×804)".
  String get label => nominalHeight == height
      ? '${height}p'
      : '${nominalHeight}p ($width×$height)';

  /// Yaklaşık dosya boyutu; site bildirmiyorsa null.
  final int? estimatedBytes;
}

class MediaInfo {
  const MediaInfo({
    required this.title,
    required this.entries,
    this.qualities = const [],
  });

  final String title;

  /// Videonun sunduğu kaliteler, en yüksek önce; bilinmiyorsa boş.
  final List<MediaQuality> qualities;

  /// Oynatma listesi öğeleri; tek videoda boş.
  final List<MediaEntry> entries;
  bool get isPlaylist => entries.isNotEmpty;
}

class MediaEntry {
  const MediaEntry({required this.url, required this.title});
  final Uri url;
  final String title;
}

/// Adresi indirmeden yoklar. [wholePlaylist] yanlışsa yalnızca tek video okunur.
Future<MediaInfo> probeMedia(
  Uri url,
  MediaToolPaths tools, {
  bool wholePlaylist = true,
  String? proxy,
  Duration timeout = const Duration(minutes: 2),
}) async {
  rejectDrmPlatform(url);
  requireMediaTools(tools);
  final ProcessResult result;
  try {
    result = await Process.run(
      tools.ytDlp!,
      [
        '--no-config',
        '--no-warnings',
        '--flat-playlist',
        wholePlaylist ? '--yes-playlist' : '--no-playlist',
        '-J',
        if (proxy != null) ...['--proxy', 'http://$proxy'],
        '--',
        url.toString(),
      ],
      environment: mediaProcessEnvironment,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
  } on ProcessException catch (e) {
    throw MediaToolMissingException('yt-dlp çalıştırılamadı: ${e.message}');
  } on Exception catch (e) {
    throw MediaDownloadException('Video bilgisi alınamadı: $e');
  }
  if (result.exitCode != 0) {
    throw classifyMediaError(result.stderr as String, result.exitCode);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(result.stdout as String);
  } on FormatException catch (e) {
    throw MediaDownloadException('yt-dlp yanıtı okunamadı: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const MediaDownloadException('yt-dlp yanıtı okunamadı');
  }
  final entries = <MediaEntry>[];
  for (final raw in (decoded['entries'] as List<dynamic>? ?? const [])) {
    if (raw is! Map<String, dynamic>) continue;
    final address = raw['webpage_url'] ?? raw['url'];
    final uri = address is String ? Uri.tryParse(address) : null;
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      continue;
    }
    entries.add(
      MediaEntry(url: uri, title: raw['title'] as String? ?? uri.toString()),
    );
  }
  return MediaInfo(
    title: decoded['title'] as String? ?? url.toString(),
    entries: entries,
    qualities: parseMediaQualities(decoded),
  );
}

/// yt-dlp'nin biçim listesinden kullanıcıya sunulacak kaliteleri çıkarır; en yüksek önce.
/// Boyut, indirmenin seçeceği biçimlere göre tahmin edilir.
List<MediaQuality> parseMediaQualities(Map<String, dynamic> info) {
  final formats = (info['formats'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .toList();
  final duration = (info['duration'] as num?)?.toDouble();

  int? sizeOf(Map<String, dynamic> format) {
    final exact = format['filesize'] ?? format['filesize_approx'];
    if (exact is num && exact > 0) return exact.round();
    final bitrate = format['tbr'];
    if (bitrate is num && bitrate > 0 && duration != null) {
      return (bitrate * 125 * duration).round();
    }
    return null;
  }

  final audios = formats
      .where((f) => f['vcodec'] == 'none' && f['acodec'] != 'none')
      .toList();
  double audioRank(Map<String, dynamic> f) =>
      (f['ext'] == 'm4a' ? 1e6 : 0) + ((f['abr'] as num?)?.toDouble() ?? 0);
  audios.sort((a, b) => audioRank(b).compareTo(audioRank(a)));
  final audioSize = audios.isEmpty ? null : sizeOf(audios.first);

  final byQuality = <int, List<Map<String, dynamic>>>{};
  for (final format in formats) {
    if (format['vcodec'] == 'none') continue;
    final height = format['height'];
    if (height is! num || height <= 0) continue;
    final width = format['width'];
    // yt-dlp'nin `res` sıralaması kısa kenarı kullanır; dikey videoda da aynı kalsın.
    final edge = width is num && width > 0 && width < height ? width : height;
    byQuality.putIfAbsent(edge.round(), () => []).add(format);
  }

  final qualities = <MediaQuality>[];
  for (final entry in byQuality.entries) {
    // yt-dlp'nin seçimiyle aynı sıra. HLS'in bildirdiği bit hızı gerçeğin çok üstünde olabilir.
    var candidates = entry.value;
    List<Map<String, dynamic>> narrow(
      bool Function(Map<String, dynamic>) test,
    ) {
      final matching = candidates.where(test).toList();
      return matching.isEmpty ? candidates : matching;
    }

    candidates = narrow((f) {
      final codec = f['vcodec'];
      return codec is String &&
          (codec.startsWith('avc') || codec.startsWith('h264'));
    });
    candidates = narrow((f) {
      final protocol = f['protocol'];
      return protocol is! String || !protocol.contains('m3u8');
    });
    candidates = narrow((f) => f['acodec'] != 'none' && f['acodec'] != null);
    int? videoSize;
    Map<String, dynamic>? chosen;
    for (final candidate in candidates) {
      final size = sizeOf(candidate);
      if (chosen == null || (size ?? 0) > (videoSize ?? 0)) {
        chosen = candidate;
        videoSize = size;
      }
    }
    final needsAudio = chosen!['acodec'] == 'none';
    final total = videoSize == null || (needsAudio && audioSize == null)
        ? null
        : videoSize + (needsAudio ? audioSize! : 0);
    final width = chosen['width'];
    final height = chosen['height'];
    qualities.add(
      MediaQuality(
        height: entry.key,
        width: width is num && height is num
            ? (width > height ? width : height).round()
            : null,
        estimatedBytes: total,
      ),
    );
  }
  qualities.sort((a, b) => b.height.compareTo(a.height));
  return qualities;
}

/// Süreci ve alt süreçlerini (ffmpeg) durdurur.
Future<void> stopMediaProcess(Process process) async {
  if (Platform.isWindows) {
    // Windows'ta kill alt süreçleri öldürmez; ffmpeg dosyayı kilitli tutardı.
    await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
  } else {
    process.kill(ProcessSignal.sigint);
  }
  await process.exitCode.timeout(
    const Duration(seconds: 5),
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return -1;
    },
  );
}
