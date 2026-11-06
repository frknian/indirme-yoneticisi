import 'dart:convert';
import 'dart:io';

import 'exceptions.dart';
import 'file_ops.dart';
import 'segment.dart';

String partPathFor(String targetPath) => '$targetPath.part';
String metaPathFor(String targetPath) => '$targetPath.dmmeta';

/// Diske hiçbir zaman yazılmaması gereken başlıklar (gizli bilgi taşırlar).
const Set<String> sensitiveHeaders = {
  'authorization',
  'cookie',
  'proxy-authorization',
};

Map<String, String> stripSensitiveHeaders(Map<String, String> headers) => {
      for (final e in headers.entries)
        if (!sensitiveHeaders.contains(e.key.toLowerCase())) e.key: e.value,
    };

/// `.dmmeta` içeriği: devam için gereken her şey.
class DownloadMetadata {
  DownloadMetadata({
    required this.url,
    required this.finalUrl,
    required this.targetPath,
    required this.size,
    required this.acceptsRanges,
    required this.segments,
    this.etag,
    this.lastModified,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().toUtc();

  factory DownloadMetadata.fromJson(Map<String, dynamic> json) {
    if (json['version'] != currentVersion) {
      throw MetadataCorruptException(
        'Desteklenmeyen metadata sürümü: ${json['version']}',
      );
    }
    return DownloadMetadata(
      url: json['url'] as String,
      finalUrl: json['finalUrl'] as String,
      targetPath: json['targetPath'] as String,
      size: json['size'] as int?,
      acceptsRanges: json['acceptsRanges'] as bool,
      etag: json['etag'] as String?,
      lastModified: json['lastModified'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
      segments: (json['segments'] as List<dynamic>)
          .map((e) => Segment.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  static const int currentVersion = 1;

  final String url;
  String finalUrl;
  final String targetPath;
  int? size;
  final bool acceptsRanges;
  String? etag;
  String? lastModified;
  final DateTime createdAt;
  final List<Segment> segments;

  int get downloadedBytes =>
      segments.fold(0, (sum, segment) => sum + segment.downloaded);

  bool get isComplete =>
      segments.isNotEmpty && segments.every((s) => s.isComplete);

  /// Parçalar dosyayı boşluksuz ve taşmasız mı kapsıyor?
  bool get isConsistent {
    if (segments.isEmpty) return false;
    if (size == null) {
      return segments.length == 1 && !segments.single.hasKnownEnd;
    }
    var cursor = 0;
    for (final segment in segments) {
      if (segment.start != cursor || !segment.hasKnownEnd) return false;
      if (segment.downloaded < 0 || segment.downloaded > segment.length!) {
        return false;
      }
      cursor = segment.end + 1;
    }
    return cursor == size;
  }

  Map<String, dynamic> toJson() => {
        'version': currentVersion,
        'url': url,
        'finalUrl': finalUrl,
        'targetPath': targetPath,
        'size': size,
        'acceptsRanges': acceptsRanges,
        'etag': etag,
        'lastModified': lastModified,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'segments': segments.map((s) => s.toJson()).toList(),
      };
}

/// Metadata'yı atomik olarak kaydeder (geçici dosya + yeniden adlandırma), böylece
/// kaydetme sırasında çökme eski kaydı bozmaz.
class MetadataStore {
  MetadataStore(this.targetPath);

  final String targetPath;

  String get metaPath => metaPathFor(targetPath);
  String get _tmpPath => '$metaPath.tmp';

  Future<void> save(DownloadMetadata metadata) async {
    try {
      final tmp = File(_tmpPath);
      final sink = await tmp.open(mode: FileMode.write);
      try {
        await sink.writeString(jsonEncode(metadata.toJson()));
        await sink.flush();
      } finally {
        await sink.close();
      }
      await retryFileOperation(() => tmp.rename(metaPath));
    } on FileSystemException catch (e) {
      throw wrapFileSystemError('Metadata yazılamadı: $metaPath', e);
    }
  }

  /// Dosya yoksa null döner; bozuksa [MetadataCorruptException] fırlatır.
  Future<DownloadMetadata?> load() async {
    final file = File(metaPath);
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      final metadata =
          DownloadMetadata.fromJson(decoded as Map<String, dynamic>);
      if (!metadata.isConsistent) {
        throw const MetadataCorruptException('Parça aralıkları tutarsız');
      }
      return metadata;
    } on MetadataCorruptException {
      rethrow;
    } on FileSystemException catch (e) {
      throw wrapFileSystemError('Metadata okunamadı: $metaPath', e);
    } on Object catch (e) {
      // FormatException, TypeError vb.: dosya kısmen yazılmış veya elle bozulmuş.
      throw MetadataCorruptException('Metadata bozuk: $metaPath', cause: e);
    }
  }

  Future<void> delete() async {
    for (final path in [metaPath, _tmpPath]) {
      await _deleteIfExists(path);
    }
  }

  Future<void> deleteAll() async {
    await delete();
    await _deleteIfExists(partPathFor(targetPath));
  }

  Future<void> _deleteIfExists(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await retryFileOperation(file.delete);
    } on FileSystemException catch (e) {
      throw wrapFileSystemError('Dosya silinemedi: $path', e);
    }
  }
}

/// `ENOSPC` (POSIX 28) ve `ERROR_DISK_FULL` (Windows 112) ayrı bir tiptir.
DiskException wrapFileSystemError(String message, FileSystemException error) {
  final code = error.osError?.errorCode;
  final isDiskFull =
      code == 28 || (Platform.isWindows && (code == 112 || code == 39));
  return isDiskFull
      ? DiskFullException('Diskte yer kalmadı. $message', cause: error)
      : DiskException(message, cause: error);
}
