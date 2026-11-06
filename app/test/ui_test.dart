import 'dart:io';

import 'package:dm_core/dm_core.dart';
import 'package:download_manager/src/app_controller.dart';
import 'package:download_manager/src/format.dart';
import 'package:download_manager/src/platform_bridge.dart';
import 'package:download_manager/src/settings.dart';
import 'package:download_manager/src/ui/home_page.dart';
import 'package:download_manager/src/ui/logo.dart';
import 'package:download_manager/src/ui/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  late Directory dir;
  late AppController controller;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('dm_ui_test');
    controller = AppController(
      settings: AppSettings(
        downloadDirectory: dir.path,
        captureToken: 'a' * 64,
        captureEnabled: false,
      ),
      queue: DownloadQueue(),
      bridge: PlatformBridge(),
      settingsFile: File('${dir.path}/settings.json'),
    );
  });

  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  Future<void> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: HomePage()),
      ),
    );
    await tester.pump();
  }

  testWidgets('boş liste durumu görünür', (tester) async {
    await pump(tester, const Size(400, 800));
    expect(find.text('Henüz indirme yok'), findsOneWidget);
    expect(find.byType(AppLogo), findsNWidgets(2));
    expect(find.text('İndirme ekle'), findsOneWidget);
  });

  testWidgets('geniş ekranda yan panel, dar ekranda tek sütun', (tester) async {
    await pump(tester, const Size(1200, 800));
    expect(find.text('Ayrıntılar için bir indirme seçin'), findsOneWidget);

    await pump(tester, const Size(400, 800));
    expect(find.text('Ayrıntılar için bir indirme seçin'), findsNothing);
  });

  testWidgets('geçersiz adres reddedilir', (tester) async {
    await pump(tester, const Size(400, 800));
    await tester.tap(find.text('İndirme ekle'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField).first, 'ftp://x/y');
    await tester.tap(find.text('İndir'));
    await tester.pump();
    expect(
      find.text('Adres http:// veya https:// ile başlamalı'),
      findsOneWidget,
    );
    expect(controller.tasks, isEmpty);
  });

  testWidgets('ayarlar: bağlantı bölümü görünür, geçersiz proxy reddedilir', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: controller,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    expect(find.text('Bağlantı'), findsOneWidget);
    expect(find.textContaining('Bağlantı zaman aşımı: 20 sn'), findsOneWidget);

    final proxy = find.widgetWithText(TextField, 'HTTP proxy');
    await tester.enterText(proxy, 'a:80; DIRECT');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(find.text('sunucu:port biçiminde olmalı'), findsOneWidget);
    expect(controller.settings.proxy, isNull);
  });

  test('bağlantı ayarları motora geçer ve kaydedilir', () async {
    final file = File('${dir.path}/c.json');
    final settings = AppSettings(
      downloadDirectory: dir.path,
      captureToken: 'a' * 64,
      connectionTimeoutSeconds: 45,
      maxAttempts: 3,
      speedLimitKiB: 500,
      proxy: 'proxy.ornek.com:3128',
    );
    final tuning = settings.tuning;
    expect(tuning.connectionTimeout, const Duration(seconds: 45));
    expect(tuning.retry.maxAttempts, 3);
    expect(tuning.maxBytesPerSecond, 500 * 1024);
    expect(tuning.proxy, 'proxy.ornek.com:3128');

    await settings.save(file);
    final loaded = await AppSettings.load(file, defaultDirectory: dir.path);
    expect(loaded.connectionTimeoutSeconds, 45);
    expect(loaded.proxy, 'proxy.ornek.com:3128');

    await file.writeAsString(
      '{"connectionTimeoutSeconds":1,"maxAttempts":99,"speedLimitKiB":-5,'
      '"proxy":"a:80; DIRECT"}',
    );
    final clamped = await AppSettings.load(file, defaultDirectory: dir.path);
    expect(clamped.connectionTimeoutSeconds, 5);
    expect(clamped.maxAttempts, 20);
    expect(clamped.speedLimitKiB, 0);
    expect(clamped.proxy, isNull, reason: 'geçersiz yönerge reddedilmeli');
  });

  test('biçimlendirme', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KiB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MiB');
    expect(formatDuration(const Duration(seconds: 42)), '42 sn');
    expect(formatDuration(const Duration(minutes: 3, seconds: 5)), '3 dk 5 sn');
    expect(formatDuration(const Duration(hours: 2, minutes: 1)), '2 sa 1 dk');
  });

  test('hatalar kullanıcı metnine çevrilir', () {
    expect(errorMessage(HttpStatusException(404)), contains('bulunamadı'));
    expect(errorMessage(HttpStatusException(403)), contains('reddetti'));
    expect(errorMessage(const DiskFullException('x')), 'Diskte yer kalmadı.');
    expect(
      errorMessage(RetriesExhaustedException(3, HttpStatusException(500))),
      contains('3 denemeden'),
    );
  });

  test('ayarlar sınırlanır, bozuk dosyada varsayılana döner', () async {
    final file = File('${dir.path}/s.json');
    await file.writeAsString(
      '{"segments":99,"maxConcurrent":0,"capturePort":80,"captureToken":"kisa"}',
    );
    final settings = await AppSettings.load(file, defaultDirectory: dir.path);
    expect(settings.segments, 16);
    expect(settings.maxConcurrent, 1);
    expect(settings.capturePort, 1024);
    expect(settings.captureToken.length, 64);

    await file.writeAsString('{bozuk');
    final fallback = await AppSettings.load(file, defaultDirectory: dir.path);
    expect(fallback.segments, 8);
    await fallback.save(file);
    final saved = await AppSettings.load(file, defaultDirectory: '/x');
    expect(saved.captureToken, fallback.captureToken);
    expect(saved.downloadDirectory, dir.path);
  });
}
