import 'package:flutter/material.dart';

/// Uygulama logosu. İkonlar da aynı çizimden üretilir (`tool/generate_icons_test.dart`).
class AppLogo extends StatelessWidget {
  const AppLogo({super.key, required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'İndirme Yöneticisi logosu',
      image: true,
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: LogoPainter()),
      ),
    );
  }
}

/// Parçalara bölünmüş ok: dosyanın paralel parçalar halinde inip tepside
/// birleşmesini anlatır. Çizim 100x100'lük bir tuvalde tanımlıdır.
class LogoPainter extends CustomPainter {
  const LogoPainter({this.background = true, this.margin = 0, this.scale = 1});

  /// Yanlış ise yalnızca işaret çizilir (Android uyarlanabilir ikonu için).
  final bool background;

  /// Tuval kenarından kesirli boşluk (macOS ikon ızgarası için).
  final double margin;

  /// İşaretin kendi ölçeği.
  final double scale;

  static const Color _top = Color(0xFF2F7BFF);
  static const Color _bottom = Color(0xFF0B2E8A);
  static const Color _mark = Color(0xFFFFFFFF);
  static const Color _tray = Color(0xFFFFC145);

  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.width * margin;
    final side = size.width - inset * 2;
    canvas.save();
    canvas.translate(inset, inset);
    canvas.scale(side / 100);

    if (background) {
      final body = RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 100, 100),
        const Radius.circular(23),
      );
      canvas.drawRRect(
        body,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_top, _bottom],
          ).createShader(const Rect.fromLTWH(0, 0, 100, 100)),
      );
    }

    canvas.translate(50, 50);
    canvas.scale(scale);
    canvas.translate(-50, -50);

    final mark = Paint()..color = _mark;
    const shaftWidth = 16.0;
    const segments = [
      (top: 13.0, height: 9.0),
      (top: 25.0, height: 9.0),
      (top: 37.0, height: 9.0),
    ];
    for (final segment in segments) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            50 - shaftWidth / 2,
            segment.top,
            shaftWidth,
            segment.height,
          ),
          const Radius.circular(2.5),
        ),
        mark,
      );
    }

    final head = Path()
      ..moveTo(26, 51)
      ..lineTo(74, 51)
      ..lineTo(50, 74)
      ..close();
    canvas.drawPath(
      head,
      Paint()
        ..color = _mark
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      head,
      Paint()
        ..color = _mark
        ..strokeWidth = 4
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(22, 80, 56, 8),
        const Radius.circular(4),
      ),
      Paint()..color = _tray,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant LogoPainter oldDelegate) =>
      oldDelegate.background != background ||
      oldDelegate.margin != margin ||
      oldDelegate.scale != scale;
}
