import 'dart:convert';
import 'dart:io';

import 'package:dm_core/dm_core.dart';

/// Uygulama ayarları; JSON olarak uygulama destek klasöründe durur.
class AppSettings {
  AppSettings({
    required this.downloadDirectory,
    required this.captureToken,
    this.segments = defaultSegments,
    this.maxConcurrent = 3,
    this.captureEnabled = true,
    this.capturePort = CaptureServer.defaultPort,
    this.connectionTimeoutSeconds = 20,
    this.maxAttempts = 8,
    this.speedLimitKiB = 0,
    this.proxy,
    this.torrentMaxPeers = 100,
    this.torrentListenPort = 0,
    this.torrentDht = true,
    this.torrentPortForwarding = false,
    this.mediaFormat = MediaFormat.mp4,
    this.mediaMaxHeight,
  });

  factory AppSettings.fromJson(
    Map<String, dynamic> json, {
    required String defaultDirectory,
  }) {
    final token = json['captureToken'];
    return AppSettings(
      downloadDirectory:
          json['downloadDirectory'] as String? ?? defaultDirectory,
      captureToken: token is String && token.length >= 32
          ? token
          : CaptureServer.generateToken(),
      segments: _clamp(json['segments'], 1, maxSegments, defaultSegments),
      maxConcurrent: _clamp(json['maxConcurrent'], 1, 10, 3),
      captureEnabled: json['captureEnabled'] as bool? ?? true,
      capturePort: _clamp(
        json['capturePort'],
        1024,
        65535,
        CaptureServer.defaultPort,
      ),
      connectionTimeoutSeconds: _clamp(
        json['connectionTimeoutSeconds'],
        5,
        120,
        20,
      ),
      maxAttempts: _clamp(json['maxAttempts'], 1, 20, 8),
      speedLimitKiB: _clamp(json['speedLimitKiB'], 0, 10 * 1024 * 1024, 0),
      mediaFormat:
          MediaFormat.values.asNameMap()[json['mediaFormat']] ??
          MediaFormat.mp4,
      mediaMaxHeight: json['mediaMaxHeight'] as int?,
      torrentMaxPeers: _clamp(json['torrentMaxPeers'], 10, 300, 100),
      torrentListenPort: _clamp(json['torrentListenPort'], 0, 65535, 0),
      torrentDht: json['torrentDht'] as bool? ?? true,
      torrentPortForwarding: json['torrentPortForwarding'] as bool? ?? false,
      proxy: switch (json['proxy']) {
        final String value when isValidProxy(value) => value,
        _ => null,
      },
    );
  }

  String downloadDirectory;
  String captureToken;
  int segments;
  int maxConcurrent;
  bool captureEnabled;
  int capturePort;
  int connectionTimeoutSeconds;
  int maxAttempts;

  /// İndirme başına KiB/sn; 0 sınırsız.
  int speedLimitKiB;

  /// `sunucu:port`; null doğrudan bağlantı.
  String? proxy;

  /// Eşzamanlı eş bağlantısı üst sınırı.
  int torrentMaxPeers;

  /// Gelen bağlantı portu; 0 otomatik.
  int torrentListenPort;
  bool torrentDht;

  /// UPnP ile yönlendiricide port açılsın mı? Varsayılan kapalı.
  bool torrentPortForwarding;

  /// Video/Ses indirmelerinin varsayılanları.
  MediaFormat mediaFormat;

  /// En yüksek video yüksekliği; null en iyi kalite.
  int? mediaMaxHeight;

  MediaOptions get mediaOptions =>
      MediaOptions(format: mediaFormat, maxHeight: mediaMaxHeight);

  /// Motorun kullandığı bağlantı ayarları.
  DownloadTuning get tuning => DownloadTuning(
    connectionTimeout: Duration(seconds: connectionTimeoutSeconds),
    retry: RetryPolicy(maxAttempts: maxAttempts),
    maxBytesPerSecond: speedLimitKiB * 1024,
    proxy: proxy,
    webPageMedia: mediaOptions,
    torrent: TorrentSettings(
      maxPeers: torrentMaxPeers,
      listenPort: torrentListenPort,
      dht: torrentDht,
      portForwarding: torrentPortForwarding,
    ),
  );

  Map<String, dynamic> toJson() => {
    'downloadDirectory': downloadDirectory,
    'captureToken': captureToken,
    'segments': segments,
    'maxConcurrent': maxConcurrent,
    'captureEnabled': captureEnabled,
    'capturePort': capturePort,
    'connectionTimeoutSeconds': connectionTimeoutSeconds,
    'maxAttempts': maxAttempts,
    'speedLimitKiB': speedLimitKiB,
    'proxy': proxy,
    'mediaFormat': mediaFormat.name,
    'mediaMaxHeight': mediaMaxHeight,
    'torrentMaxPeers': torrentMaxPeers,
    'torrentListenPort': torrentListenPort,
    'torrentDht': torrentDht,
    'torrentPortForwarding': torrentPortForwarding,
  };

  static int _clamp(Object? value, int low, int high, int fallback) =>
      value is int ? value.clamp(low, high) : fallback;

  /// Dosya yoksa veya bozuksa varsayılanlarla başlar.
  static Future<AppSettings> load(
    File file, {
    required String defaultDirectory,
  }) async {
    Map<String, dynamic> json = const {};
    try {
      if (await file.exists()) {
        json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
    } on FormatException {
      json = const {};
    } on TypeError {
      json = const {};
    }
    return AppSettings.fromJson(json, defaultDirectory: defaultDirectory);
  }

  Future<void> save(File file) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await retryFileOperation(() => tmp.rename(file.path));
  }
}
