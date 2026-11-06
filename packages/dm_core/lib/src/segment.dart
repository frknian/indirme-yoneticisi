/// Dosyanın bir bayt aralığı ve bu aralığın ilerlemesi.
class Segment {
  Segment({
    required this.index,
    required this.start,
    required this.end,
    this.downloaded = 0,
  });

  factory Segment.fromJson(Map<String, dynamic> json) => Segment(
        index: json['index'] as int,
        start: json['start'] as int,
        end: json['end'] as int,
        downloaded: json['downloaded'] as int,
      );

  /// [end] için "boyut bilinmiyor" değeri.
  static const int unknownEnd = -1;

  final int index;

  /// Aralığın ilk baytı.
  final int start;

  /// Aralığın son baytı (dahil); boyut bilinmiyorsa [unknownEnd].
  final int end;

  /// Diske yazılmış ve flush edilmiş bayt sayısı.
  int downloaded;

  bool get hasKnownEnd => end != unknownEnd;
  int? get length => hasKnownEnd ? end - start + 1 : null;
  int get nextByte => start + downloaded;
  bool get isComplete => hasKnownEnd && downloaded >= length!;

  Map<String, dynamic> toJson() => {
        'index': index,
        'start': start,
        'end': end,
        'downloaded': downloaded,
      };
}

/// [size] baytlık dosyayı en fazla [count] parçaya böler.
///
/// Parçalar [minSegmentSize] değerinden küçük olmayacak şekilde sayı azaltılır;
/// böylece küçük dosyalar için gereksiz bağlantı açılmaz.
List<Segment> planSegments(int size, int count, {int minSegmentSize = 1}) {
  if (size <= 0) throw ArgumentError.value(size, 'size', 'pozitif olmalı');
  if (count < 1) throw ArgumentError.value(count, 'count', 'en az 1 olmalı');
  if (minSegmentSize < 1) {
    throw ArgumentError.value(minSegmentSize, 'minSegmentSize');
  }
  final maxByMinSize = size ~/ minSegmentSize;
  final effective =
      maxByMinSize < 1 ? 1 : (count < maxByMinSize ? count : maxByMinSize);
  final base = size ~/ effective;
  final extra = size % effective;
  final segments = <Segment>[];
  var cursor = 0;
  for (var i = 0; i < effective; i++) {
    final length = base + (i < extra ? 1 : 0);
    segments.add(Segment(index: i, start: cursor, end: cursor + length - 1));
    cursor += length;
  }
  return segments;
}
