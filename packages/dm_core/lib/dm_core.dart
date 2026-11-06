/// Parçalı, devam ettirilebilir indirme motoru.
///
/// UI'dan bağımsızdır; `dart:io` dışında platform bağımlılığı yoktur.
library;

export 'src/capture_server.dart';
export 'src/downloader.dart' show DownloadTask;
export 'src/exceptions.dart';
export 'src/file_name.dart' show sanitizeFileName;
export 'src/file_ops.dart' show retryFileOperation;
export 'src/hash_verify.dart' show isValidSha256, normalizeSha256, sha256OfFile;
export 'src/media.dart'
    show
        MediaEntry,
        MediaFormat,
        MediaInfo,
        MediaOptions,
        MediaToolPaths,
        isLikelyMediaUrl,
        isMediaSupported,
        locateMediaTools,
        mediaInstallHint,
        mediaToolVersion,
        probeMedia;
export 'src/metadata_store.dart'
    show
        DownloadMetadata,
        MetadataStore,
        metaPathFor,
        partPathFor,
        stripSensitiveHeaders;
export 'src/models.dart';
export 'src/probe.dart' show ProbeResult, probeUrl, validateDownloadUri;
export 'src/queue.dart';
export 'src/retry.dart' show RetryPolicy;
export 'src/segment.dart' show Segment, planSegments;
export 'src/speed_meter.dart' show SpeedMeter;
export 'src/torrent_worker.dart' show deleteTorrentFolder;
