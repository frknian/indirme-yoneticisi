// Logo PNG'lerini üretir. Çalıştırma:
//   flutter test tool/generate_icons_test.dart
//   python3 tool/install_icons.py
import 'dart:io';
import 'dart:ui' as ui;

import 'package:download_manager/src/ui/logo.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _render(String path, int size, LogoPainter painter) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  painter.paint(canvas, ui.Size.square(size.toDouble()));
  final image = await recorder.endRecording().toImage(size, size);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await File(path).writeAsBytes(bytes!.buffer.asUint8List());
}

void main() {
  testWidgets('logo PNG üret', (tester) async {
    await tester.runAsync(() async {
      Directory('assets/logo').createSync(recursive: true);
      // Tam kare: Windows, eklenti, genel kullanım.
      await _render('assets/logo/logo_1024.png', 1024, const LogoPainter());
      // macOS ızgarası: 824/1024 gövde, çevrede boşluk.
      await _render(
        'assets/logo/logo_macos_1024.png',
        1024,
        const LogoPainter(margin: 100 / 1024),
      );
      // Android uyarlanabilir ön plan: işaret güvenli bölgede, arka plan yok.
      await _render(
        'assets/logo/logo_foreground_432.png',
        432,
        const LogoPainter(background: false, scale: 0.62),
      );
    });
  });
}
