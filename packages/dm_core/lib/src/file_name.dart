import 'dart:convert';

/// Ağdan gelen dosya adını güvenli hale getirir: dizin geçişi (`../`), mutlak
/// yol, kontrol karakteri ve Windows'a özgü ayrılmış adları temizler.
String sanitizeFileName(String raw, {String fallback = 'download'}) {
  // Yalnızca son yol bileşeni kullanılır.
  var name = raw.split(RegExp(r'[/\\]')).last;
  name = name.replaceAll(RegExp(r'[\x00-\x1f\x7f<>:"|?*]'), '_');
  // Windows sondaki nokta ve boşlukları sessizce siler.
  name = name.trim().replaceFirst(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') return fallback;

  final dot = name.indexOf('.');
  final stem = (dot == -1 ? name : name.substring(0, dot)).toUpperCase();
  if (const {'CON', 'PRN', 'AUX', 'NUL'}.contains(stem) ||
      RegExp(r'^(COM|LPT)[1-9]$').hasMatch(stem)) {
    name = '_$name';
  }
  return _truncate(name);
}

/// Çoğu dosya sistemi ad başına 255 bayt izin verir; `.part`/`.dmmeta.tmp`
/// ekleri için pay bırakılır ve uzantı korunur.
String _truncate(String name, {int maxBytes = 200}) {
  if (utf8.encode(name).length <= maxBytes) return name;
  final dot = name.lastIndexOf('.');
  final hasExt = dot > 0 && name.length - dot <= 16;
  final ext = hasExt ? name.substring(dot) : '';
  final runes = (hasExt ? name.substring(0, dot) : name).runes.toList();
  final budget = maxBytes - utf8.encode(ext).length;
  while (runes.isNotEmpty &&
      utf8.encode(String.fromCharCodes(runes)).length > budget) {
    runes.removeLast();
  }
  return '${String.fromCharCodes(runes)}$ext';
}

/// `Content-Disposition` başlığından dosya adını çıkarır.
/// RFC 6266'ya göre `filename*` varsa `filename`e tercih edilir.
String? fileNameFromContentDisposition(String? header) {
  if (header == null) return null;
  final extended = RegExp(
    r"""filename\*\s*=\s*([^']*)'[^']*'([^;]+)""",
    caseSensitive: false,
  ).firstMatch(header);
  if (extended != null) {
    final charset = extended[1]!.trim().toLowerCase();
    final encoded = extended[2]!.trim().replaceAll('"', '');
    final decoded = _percentDecode(encoded, charset);
    if (decoded != null && decoded.isNotEmpty) return decoded;
  }
  final plain = RegExp(
    r'''(?:^|[;\s])filename\s*=\s*(?:"((?:[^"\\]|\\.)*)"|([^;]+))''',
    caseSensitive: false,
  ).firstMatch(header);
  if (plain == null) return null;
  final quoted = plain[1];
  final value = quoted != null
      ? quoted.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!)
      : plain[2]!.trim();
  return value.isEmpty ? null : _repairLatin1(value);
}

String? _percentDecode(String value, String charset) {
  try {
    final bytes = <int>[];
    for (var i = 0; i < value.length; i++) {
      final c = value.codeUnitAt(i);
      if (c == 0x25) {
        bytes.add(int.parse(value.substring(i + 1, i + 3), radix: 16));
        i += 2;
      } else {
        bytes.add(c);
      }
    }
    return charset == 'iso-8859-1' ? latin1.decode(bytes) : utf8.decode(bytes);
  } on FormatException {
    return null;
  } on RangeError {
    return null;
  }
}

/// `dart:io` başlıkları Latin-1 çözer. Sunucu ham UTF-8 gönderdiyse düzeltir.
String _repairLatin1(String value) {
  try {
    return utf8.decode(latin1.encode(value));
  } on FormatException {
    return value;
  } on ArgumentError {
    return value;
  }
}

/// URL yolunun son bileşeninden dosya adı çıkarır.
String? fileNameFromUri(Uri uri) {
  final segments = uri.pathSegments.where((s) => s.isNotEmpty);
  return segments.isEmpty ? null : segments.last;
}
