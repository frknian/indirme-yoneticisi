# İndirme Yöneticisi

Parçalı, duraklatılabilir ve çökmeden kurtulabilen indirme yöneticisi. Flutter ile
macOS ve Windows'ta, ayrıca Linux ve Android'de tek kod tabanından çalışmak üzere yazıldı. Sunucu `Range`
destekliyorsa dosyayı en fazla 16 parçaya böler ve paralel indirir.

## Yapı

| Klasör | İçerik |
|---|---|
| `packages/dm_core` | Saf Dart motoru: yoklama, parçalı indirme, kuyruk, metadata, yerel yakalama sunucusu, CLI |
| `app` | Flutter arayüzü ve Android servisi |
| `extension` | Chrome eklentisi (Manifest V3) |

## Kurulum

Uygulama her işletim sisteminde kendi üzerinde derlenir: macOS sürümü Mac'te, Windows sürümü
Windows'ta. Hazır paket yoktur.

### macOS

**Gerekenler:** macOS 12 veya üstü, [App Store'dan Xcode](https://apps.apple.com/app/xcode/id497799835).

1. Xcode'u bir kez açıp lisansı kabul edin.
2. Flutter'ı kurun:

   ```bash
   brew install --cask flutter
   ```

3. Eksik var mı kontrol edin. **Xcode** satırında hata olmamalı; Android ve Chrome uyarıları
   masaüstü derlemesini etkilemez:

   ```bash
   flutter doctor
   ```

4. Depo klasöründe uygulamayı derleyin:

   ```bash
   cd app && flutter pub get && flutter build macos --release
   ```

5. Uygulamayı Applications klasörüne kopyalayıp açın:

   ```bash
   cp -R build/macos/Build/Products/Release/download_manager.app /Applications/
   ```

   ```bash
   open /Applications/download_manager.app
   ```

Uygulama geliştirici sertifikasıyla imzalı değildir. Başka bir Mac'e kopyalarsanız ilk açılışta
Gatekeeper uyarı verir; uygulamaya sağ tıklayıp **Aç**'ı seçmek gerekir.

### Windows

**Gerekenler:** 64 bit Windows 10 veya 11. Komutları PowerShell'de çalıştırın.

1. Git'i kurun:

   ```powershell
   winget install --id Git.Git -e
   ```

2. Visual Studio'yu C++ masaüstü bileşeniyle kurun. Visual Studio Code bunun yerine geçmez:

   ```powershell
   winget install --id Microsoft.VisualStudio.2022.Community -e --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --passive"
   ```

3. Flutter'ı indirin:

   ```powershell
   git clone -b stable https://github.com/flutter/flutter.git C:\dev\flutter
   ```

4. Flutter'ı PATH'e ekleyin, sonra PowerShell'i kapatıp yeniden açın:

   ```powershell
   [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable("Path", "User") + ";C:\dev\flutter\bin", "User")
   ```

5. **Geliştirici Modu**nu açın. Flutter eklentileri sembolik bağlantı kullandığı için bu olmadan
   derleme durur. Açılan ayarlar sayfasında seçeneği etkinleştirin:

   ```powershell
   start ms-settings:developers
   ```

6. Eksik var mı kontrol edin. **Visual Studio** satırında hata olmamalı:

   ```powershell
   flutter doctor
   ```

7. Depo klasöründe uygulamayı derleyin:

   ```powershell
   cd app; flutter pub get; flutter build windows --release
   ```

8. Uygulamayı açın:

   ```powershell
   .\build\windows\x64\runner\Release\download_manager.exe
   ```

Uygulamayı başka bir yere taşırken yalnızca `.exe` dosyasını değil, `Release` klasörünün tamamını
kopyalayın; yanındaki DLL'ler ve `data` klasörü de gereklidir.

### Chrome eklentisi (macOS ve Windows)

İsteğe bağlıdır. Chrome'daki indirmeleri uygulamaya gönderir.

1. Uygulamayı açık bırakın.
2. Chrome'da `chrome://extensions` sayfasını açıp **Geliştirici modu**nu etkinleştirin.
3. **Paketlenmemiş öğe yükle** ile depodaki `extension` klasörünü seçin.
4. Uygulamada **Ayarlar > Eşleştirme anahtarı** değerini kopyalayın.
5. Açılan eklenti ayarlarına yapıştırıp **Kaydet ve dene**'ye basın. "Uygulamaya bağlı" yazmalıdır.

### Kaldırma

| | Uygulama | Ayarlar ve indirme listesi |
|---|---|---|
| macOS | `/Applications/download_manager.app` | `~/Library/Application Support/dev.dmapp.downloadManager` |
| Windows | `Release` klasörü | `%APPDATA%\dev.dmapp\download_manager` |

İndirilen dosyalar bu klasörlerde değildir, kaldırma onları etkilemez.

## Geliştirme

Her iki sistemde de aynı komutlar çalışır.

```bash
cd app && flutter run -d macos
```

Windows'ta `-d windows` kullanın. Linux ve Android de desteklenir; Android için ayrıca Android
SDK ve JDK 17 gerekir.

Çekirdeği arayüz olmadan kullanmak için:

```bash
cd packages/dm_core && dart pub get
```

```bash
dart run bin/cli.dart https://ornek.com/dosya.zip -o ~/Downloads -s 8 --hash
```

Ctrl+C indirmeyi duraklatır. Aynı komutu tekrar çalıştırmak kaldığı yerden devam ettirir.
`--sha256 <özet>` dosyayı doğrular, `dart run bin/cli.dart --help` tüm seçenekleri listeler.

## Testler

```bash
cd packages/dm_core && dart analyze && dart test
```

```bash
cd app && flutter analyze && flutter test
```

```bash
cd extension && npm test
```

Elle deneme için hızı sınırlanabilen yerel bir Range sunucusu vardır:

```bash
cd packages/dm_core && dart run tool/serve.dart 50 8099 2048
```

Android emülatöründen bu sunucuya `http://10.0.2.2:8099/test.bin` ile erişilir.

## Mimari özeti

- **Akış:** `HEAD` ile yokla, parçaları planla, her parça için isolate başlat, `<dosya>.part`
  içine yaz, gerekirse SHA-256 doğrula, son ada taşı.
- **Geri düşme:** `Range` veya boyut yoksa tek bağlantıya düşer. `HEAD` reddedilirse ya da
  `Accept-Ranges` belirsizse `Range: bytes=0-0` ile gerçek davranışa bakar.
- **Dayanıklılık:** `<dosya>.dmmeta` atomik yazılır ve yalnızca diske flush edilmiş baytları
  sayar. Bu yüzden ani kapanmada kayıt, diskteki veriden fazlasını iddia edemez.
- **Değişen dosya:** `ETag`, `Last-Modified` veya boyut değişirse indirme baştan başlar.
  İndirme sırasındaki değişim `If-Range` ile yakalanır.
- **Yeniden deneme:** `429`, `503`, diğer geçici 5xx kodları ve kopmalarda üstel geri çekilme
  uygulanır, `Retry-After`'a uyulur. `429` ve `503` eşzamanlı bağlantı sayısını yarıya indirir.
- **UI bağlantısı:** arayüz çekirdeğe yalnızca `Stream` üzerinden bağlanır (`DownloadTask.progress`,
  `DownloadQueue.changes`).
- **Android:** önbelleğe alınmış `FlutterEngine` Activity'den bağımsız yaşar; foreground service
  süreci ayakta tutar. Biten dosya MediaStore ile İndirilenler'e taşınır.
- **Tarayıcı bağlantısı:** yalnızca `127.0.0.1` dinlenir. İstekler `Host`, `Origin` ve eşleştirme
  anahtarından geçer, böylece web siteleri indirme başlatamaz.

Kararlar için [DECISIONS.md](DECISIONS.md), elle denenecekler için
[TEST_CHECKLIST.md](TEST_CHECKLIST.md).

## Bilinen eksikler

- Çerezler eklentiden uygulamaya aktarılmaz; oturum gerektiren indirmeler başarısız olabilir.
  Bu dosyalarda eklenti açılır penceresinden devralmayı kapatın.
- `Authorization` ve `Cookie` başlıkları diske yazılmaz. Bu başlıklarla başlatılan indirme,
  uygulama yeniden açıldıktan sonra devam edemeyebilir.
- Biten parça, yavaş parçanın kalan işini devralmaz (dinamik bölme yok).
- Range desteklemeyen sunucuda duraklatılan indirme baştan başlar. Arayüz bunu belirtir.
- Android 15'te `dataSync` servisinin günlük süre sınırı vardır. Süre dolunca indirmeler
  duraklatılır ve elle sürdürülür.
- Android 9 ve altında dosyalar uygulama klasöründe kalır.
- Windows'ta çok büyük dosyalarda NTFS dosyayı sıfırla doldurduğu için ilerleme başta bir süre
  duraksayabilir.
- Release APK şimdilik debug anahtarıyla imzalanır; Play Store için kendi anahtarınız gerekir.
- Uygulama DRM korumasını aşmaya çalışmaz. Telifli içerik sorumluluğu kullanıcıya aittir.
