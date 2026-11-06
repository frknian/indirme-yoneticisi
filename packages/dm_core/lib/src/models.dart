import 'exceptions.dart';
import 'retry.dart';

/// Bir indirmenin yaşam döngüsü.
enum DownloadState {
  /// Başlamak için sıra bekliyor.
  queued,
  probing,
  downloading,
  paused,
  verifying,
  completed,
  failed,
  canceled;

  /// Çalışan bir isolate/ağ işlemi var mı?
  bool get isActive =>
      this == probing || this == downloading || this == verifying;

  /// Bu durumdan kendiliğinden çıkılmaz.
  bool get isTerminal => this == completed || this == canceled;
}

/// Parça sayısı sınırları (CLAUDE.md: varsayılan 8, üst sınır 16).
const int defaultSegments = 8;
const int maxSegments = 16;

/// Yeni bir indirme isteği.
class DownloadRequest {
  DownloadRequest({
    required this.url,
    required this.directory,
    this.fileName,
    int segments = defaultSegments,
    this.headers = const {},
    this.expectedSha256,
    this.computeSha256 = false,
  }) : segments = segments.clamp(1, maxSegments);

  final Uri url;
  final String directory;

  /// Boşsa sunucudan öğrenilir.
  final String? fileName;
  final int segments;
  final Map<String, String> headers;
  final String? expectedSha256;

  /// Beklenen değer verilmese bile özet hesaplansın mı?
  final bool computeSha256;
}

/// Motorun ince ayarları. Varsayılanlar gerçek kullanım içindir; testler kısaltır.
class DownloadTuning {
  const DownloadTuning({
    this.retry = const RetryPolicy(),
    this.minSegmentSize = 1024 * 1024,
    this.connectionTimeout = const Duration(seconds: 20),
    this.idleTimeout = const Duration(seconds: 30),
    this.progressInterval = const Duration(milliseconds: 250),
    this.metadataInterval = const Duration(seconds: 1),
    this.flushInterval = const Duration(seconds: 1),
    this.maxRemoteRestarts = 3,
    this.userAgent = 'dm_core/0.1',
    this.maxBytesPerSecond = 0,
    this.proxy,
    this.torrent = const TorrentSettings(),
  });

  final RetryPolicy retry;

  /// Dosya bu değerin altındaki parçalara bölünmez.
  final int minSegmentSize;
  final Duration connectionTimeout;

  /// Bu süre boyunca veri gelmezse bağlantı kopmuş sayılır.
  final Duration idleTimeout;
  final Duration progressInterval;
  final Duration metadataInterval;
  final Duration flushInterval;

  /// Sunucudaki dosya değiştiği için en fazla kaç kez baştan başlanır.
  final int maxRemoteRestarts;
  final String userAgent;

  /// İndirme başına hız sınırı; 0 sınırsız demektir.
  final int maxBytesPerSecond;

  /// HTTP proxy, `sunucu:port` biçiminde; null doğrudan bağlantı demektir.
  final String? proxy;

  /// Torrent bağlantı ayarları.
  final TorrentSettings torrent;
}

/// Torrent motorunun bağlantı ayarları.
class TorrentSettings {
  const TorrentSettings({
    this.maxPeers = 100,
    this.listenPort = 0,
    this.dht = true,
    this.portForwarding = false,
    this.stallTimeout = const Duration(seconds: 45),
    this.metadataTimeout = const Duration(minutes: 3),
    this.allowLoopbackPeers = false,
  });

  /// Eşzamanlı eş bağlantısı üst sınırı.
  final int maxPeers;

  /// Gelen bağlantı portu; 0 işletim sistemine bırakır.
  final int listenPort;
  final bool dht;

  /// UPnP/NAT-PMP ile yönlendiricide port açılsın mı? Yönlendirici ayarını
  /// değiştirdiği için yalnızca kullanıcı isterse açılır.
  final bool portForwarding;

  /// İlerleme bu kadar süre durursa motor yeniden başlatılır.
  final Duration stallTimeout;

  /// Magnet bilgisinin alınması için en uzun süre.
  final Duration metadataTimeout;

  /// Yalnızca yerel testler içindir; gerçek kullanımda loopback eş reddedilir.
  final bool allowLoopbackPeers;
}

/// Bu adres torrent olarak mı indirilmeli?
bool isTorrentUri(Uri uri) {
  if (uri.isScheme('magnet')) return true;
  if (uri.isScheme('file') || uri.isScheme('http') || uri.isScheme('https')) {
    return uri.path.toLowerCase().endsWith('.torrent');
  }
  return false;
}

/// `sunucu:port` biçimini doğrular. `findProxy` yönergesine başka bir şey
/// karışmasın diye yalnızca ad, IPv4 ve port karakterlerine izin verilir.
bool isValidProxy(String value) {
  final match = RegExp(r'^[A-Za-z0-9.-]+:(\d{1,5})$').firstMatch(value);
  if (match == null) return false;
  final port = int.parse(match[1]!);
  return port >= 1 && port <= 65535;
}

/// Ekranda parça çubuğu çizmek için anlık parça durumu.
class SegmentProgress {
  const SegmentProgress({
    required this.index,
    required this.start,
    required this.end,
    required this.downloaded,
  });

  final int index;
  final int start;
  final int end;
  final int downloaded;

  int? get length => end == -1 ? null : end - start + 1;
}

/// UI'ın çekirdekten aldığı tek veri tipi.
class DownloadProgress {
  const DownloadProgress({
    required this.state,
    this.totalBytes,
    this.downloadedBytes = 0,
    this.bytesPerSecond = 0,
    this.eta,
    this.segments = const [],
    this.activeConnections = 0,
    this.resumable = true,
    this.restarts = 0,
    this.isTorrent = false,
    this.peers = 0,
    this.seeds = 0,
    this.uploadBytesPerSecond = 0,
    this.fileName,
    this.filePath,
    this.sha256,
    this.error,
  });

  final DownloadState state;

  /// Bilinmiyorsa null.
  final int? totalBytes;
  final int downloadedBytes;
  final double bytesPerSecond;
  final Duration? eta;
  final List<SegmentProgress> segments;
  final int activeConnections;

  /// Yanlış ise duraklatılırsa indirme baştan başlar.
  final bool resumable;

  /// Sunucudaki dosya değiştiği için baştan başlama sayısı.
  final int restarts;
  final bool isTorrent;

  /// Bağlı eş ve kaynak sayısı (yalnızca torrent).
  final int peers;
  final int seeds;
  final double uploadBytesPerSecond;
  final String? fileName;
  final String? filePath;
  final String? sha256;
  final DownloadException? error;

  /// 0..1 arası oran; boyut bilinmiyorsa null.
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    return (downloadedBytes / total).clamp(0.0, 1.0);
  }

  DownloadProgress copyWith({
    DownloadState? state,
    int? totalBytes,
    int? downloadedBytes,
    double? bytesPerSecond,
    Duration? eta,
    bool clearEta = false,
    List<SegmentProgress>? segments,
    int? activeConnections,
    bool? resumable,
    int? restarts,
    bool? isTorrent,
    int? peers,
    int? seeds,
    double? uploadBytesPerSecond,
    String? fileName,
    String? filePath,
    String? sha256,
    DownloadException? error,
    bool clearError = false,
  }) =>
      DownloadProgress(
        state: state ?? this.state,
        totalBytes: totalBytes ?? this.totalBytes,
        downloadedBytes: downloadedBytes ?? this.downloadedBytes,
        bytesPerSecond: bytesPerSecond ?? this.bytesPerSecond,
        eta: clearEta ? null : (eta ?? this.eta),
        segments: segments ?? this.segments,
        activeConnections: activeConnections ?? this.activeConnections,
        resumable: resumable ?? this.resumable,
        restarts: restarts ?? this.restarts,
        isTorrent: isTorrent ?? this.isTorrent,
        peers: peers ?? this.peers,
        seeds: seeds ?? this.seeds,
        uploadBytesPerSecond: uploadBytesPerSecond ?? this.uploadBytesPerSecond,
        fileName: fileName ?? this.fileName,
        filePath: filePath ?? this.filePath,
        sha256: sha256 ?? this.sha256,
        error: clearError ? null : (error ?? this.error),
      );
}
