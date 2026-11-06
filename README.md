# İndirme Yöneticisi

Parçalı, duraklatılabilir ve çökmeden kurtulabilen; torrent, video ve oynatma listesi de indirebilen indirme yöneticisi. Flutter ile
macOS ve Windows'ta, ayrıca Linux ve Android'de tek kod tabanından çalışmak üzere yazıldı. Sunucu `Range`
destekliyorsa dosyayı en fazla 16 parçaya böler ve paralel indirir.

## Yapı

| Klasör | İçerik |
|---|---|
| `packages/dm_core` | Saf Dart motoru: yoklama, parçalı indirme, torrent, kuyruk, metadata, yerel yakalama sunucusu, CLI |
| `packages/third_party/dtorrent_task_v2` | Yamalanmış torrent motoru (BSD 3-Clause), yamalar `PATCHES.md` içinde |
| `app` | Flutter arayüzü ve Android servisi |
| `extension` | Chrome eklentisi (Manifest V3) |

## Hızlı kurulum

Geliştirici araçları gerekmez. [Son sürüm sayfasından](https://github.com/frknian/indirme-yoneticisi/releases/latest)
bilgisayarınıza uygun dosyayı indirin. Uygulama imzasız olduğu için ilk açılışta bir güvenlik uyarısı çıkar.

### Mac

1. `IndirmeYoneticisi-macos.zip` dosyasını indirip açın.
2. `download_manager` uygulamasını **Uygulamalar** klasörüne taşıyın ve çift tıklayın.
3. Uyarı çıkarsa **Bitti**'ye basın. **Sistem Ayarları > Gizlilik ve Güvenlik** bölümünün altındaki **Yine de Aç** düğmesine basın.

### Windows

1. `IndirmeYoneticisi-windows.zip` dosyasına sağ tıklayıp **Tümünü ayıkla**'yı seçin. ZIP'in içinden doğrudan çalıştırmayın.
2. Çıkan klasördeki `download_manager.exe` dosyasını açın. Yanındaki dosyaları silmeyin veya taşımayın.
3. "Windows kişisel bilgisayarınızı korudu" uyarısı çıkarsa **Ek bilgi > Yine de çalıştır**'a basın.

### Video ve MP3 için

Normal dosya ve torrent indirmek için bu adım gerekmez. Video ve MP3 için `yt-dlp` ve `ffmpeg` gerekir.

Windows'ta PowerShell'e yazın:

```powershell
winget install --id yt-dlp.yt-dlp -e
```

Mac'te önce [Homebrew](https://brew.sh) kurun, sonra Terminal'e yazın:

```bash
brew install yt-dlp ffmpeg
```

Ardından uygulamayı yeniden başlatın. **Ayarlar > Video** bölümünde araçlar görünmelidir.

## Kaynaktan derleme

Uygulamayı kendiniz derlemek istiyorsanız aşağıdaki adımları izleyin. Her işletim sistemi kendi üzerinde
derlenir: macOS sürümü Mac'te, Windows sürümü Windows'ta.

### macOS

**Gerekenler:** macOS 12 veya üstü, [App Store'dan Xcode](https://apps.apple.com/app/xcode/id497799835).

1. Xcode'u bir kez açıp lisansı kabul edin.
2. Flutter'ı kurun:

   ```bash
   brew install --cask flutter
   ```

3. Video indirme için `yt-dlp` ve `ffmpeg` kurun:

   ```bash
   brew install yt-dlp ffmpeg
   ```

4. Eksik var mı kontrol edin. **Xcode** satırında hata olmamalı; Android ve Chrome uyarıları
   masaüstü derlemesini etkilemez:

   ```bash
   flutter doctor
   ```

5. Depo klasöründe uygulamayı derleyin:

   ```bash
   cd app && flutter pub get && flutter build macos --release
   ```

6. Uygulamayı Applications klasörüne kopyalayıp açın:

   ```bash
   cp -R build/macos/Build/Products/Release/download_manager.app /Applications/
   ```

   ```bash
   open /Applications/download_manager.app
   ```

Uygulama geliştirici sertifikasıyla imzalı değildir. Başka bir Mac'e kopyalarsanız ilk açılışta
Gatekeeper uyarı verir; **Sistem Ayarları > Gizlilik ve Güvenlik** bölümünden **Yine de Aç**'ı seçmek gerekir.

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

5. Video indirme için `yt-dlp` kurun; `ffmpeg` de onunla birlikte gelir:

   ```powershell
   winget install --id yt-dlp.yt-dlp -e
   ```

6. **Geliştirici Modu**nu açın. Flutter eklentileri sembolik bağlantı kullandığı için bu olmadan
   derleme durur. Açılan ayarlar sayfasında seçeneği etkinleştirin:

   ```powershell
   start ms-settings:developers
   ```

7. Eksik var mı kontrol edin. **Visual Studio** satırında hata olmamalı:

   ```powershell
   flutter doctor
   ```

8. Depo klasöründe uygulamayı derleyin:

   ```powershell
   cd app; flutter pub get; flutter build windows --release
   ```

9. Uygulamayı açın:

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

### Windows Güvenlik Duvarı

İlk torrent indirmesinde Windows, uygulamanın gelen bağlantı dinlemesi için izin isteyebilir. İzin
vermezseniz indirme yine çalışır, yalnızca bağlanılabilen eş sayısı azalabilir.

### Kaldırma

| | Uygulama | Ayarlar ve indirme listesi |
|---|---|---|
| macOS | `/Applications/download_manager.app` | `~/Library/Application Support/dev.dmapp.downloadManager` |
| Windows | `Release` klasörü | `%APPDATA%\dev.dmapp\download_manager` |

İndirilen dosyalar bu klasörlerde değildir, kaldırma onları etkilemez.

## Kullanım

**İndirme ekle** penceresine adres yapıştırın. Şunlar kabul edilir:

- `http://` ve `https://` dosya bağlantıları
- `magnet:` bağlantıları
- `.torrent` ile biten adresler, ya da **Torrent dosyası seç** ile seçilen bir dosya

Android'de paylaş menüsü ve magnet bağlantıları da aynı pencereyi açar.

### Video ve ses

Video sayfası bağlantısı yapıştırınca pencere **Video / Ses** kipine geçer; bilinen video siteleri dışındaki
web sayfaları da sunucuya sorularak algılanır. Dosya kipinde veya Chrome eklentisinden gelen bir adres web sayfası
çıkarsa indirme kendiliğinden video olarak denenir. Video bulunamazsa açık bir hata verir. Masaüstünde çalışır.

- **Biçim:** MP4 (video) veya MP3 (yalnızca ses). Kaynak başka biçimdeyse `ffmpeg` dönüştürür.
- **Kalite:** bağlantıyı yapıştırınca video sorgulanır; yalnızca o videoda bulunan kaliteler yaklaşık
  dosya boyutlarıyla listelenir. Geniş ekran filmler bilinen adıyla görünür, örneğin `1080p (1920×804)`.
  Site bilgi vermezse veya oynatma listesinde standart seçenekler üst sınır olarak uygulanır.
  1080p üstü kaliteler çoğu sitede VP9 veya AV1'dir; QuickTime açamazsa VLC kullanın.
- **Oynatma listesi:** **Oynatma listesinin tamamı** açıkken her video ayrı indirme olarak eklenir ve
  listenin adını taşıyan klasöre iner. Duraklatma ve iptal her video için ayrıdır.
- **Desteklenen siteler:** YouTube, Vimeo ve `yt-dlp`'nin desteklediği diğer siteler, ayrıca doğrudan
  `.m3u8` bağlantıları.

**Dizi ve filmler:** korumasız yayınlar indirilebilir. Netflix, Disney+, Prime Video, BluTV ve Exxen
gibi DRM korumalı platformlar açık bir hatayla reddedilir; uygulama DRM'i aşmaz. Telif hakkı ve sitenin
kullanım koşullarına uymak kullanıcının sorumluluğundadır.

Siteler değiştikçe `yt-dlp` eskir. Bir site çalışmayı bırakırsa önce güncelleyin:

```bash
brew upgrade yt-dlp
```

```powershell
winget upgrade --id yt-dlp.yt-dlp -e
```

### Torrent

Torrent indirirken IP adresiniz diğer eşlere görünür ve indirdiğiniz parçalar onlara da gönderilir.
İndirme bitince gönderim durur. Telifli içerik sorumluluğu kullanıcıya aittir.

### Ayarlar

| Bölüm | Ayar | Varsayılan |
|---|---|---|
| Genel | Parça sayısı, aynı anda indirme | 8, 3 |
| Bağlantı | Zaman aşımı, yeniden deneme | 20 sn, 8 |
| Bağlantı | İndirme başına hız sınırı, HTTP proxy | Kapalı |
| Torrent | Eş bağlantısı sınırı, gelen bağlantı portu | 100, otomatik |
| Torrent | DHT | Açık |
| Torrent | Yönlendiricide port açma (UPnP) | Kapalı |

UPnP modemde kalıcı bir yönlendirme kaydı bırakabilir, bu yüzden kendiliğinden açılmaz.

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

`.github/workflows/ci.yml` aynı testleri ve derlemeleri macOS ile Windows'ta çalıştırır; Windows ve
macOS derlemeleri iş sonucundan indirilebilir.

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
- **Torrent:** motor kendi isolate'ında çalışır ve parçaları SHA-1 ile doğrular. Torrent içindeki `../`
  gibi yollar, sembolik bağlantılar ve çalıştırma izinleri reddedilir. İlerleme 45 saniye durursa motor
  yeniden başlatılır.
- **Video:** `yt-dlp` ayrı süreç olarak çalışır, yarım dosyalar görev başına geçici klasörde tutulur. Çıktısı
  aynı ilerleme akışına çevrilir. Bağlantı ayarları (hız sınırı, proxy, zaman aşımı) burada da geçerlidir.
- **Tarayıcı bağlantısı:** yalnızca `127.0.0.1` dinlenir. İstekler `Host`, `Origin` ve eşleştirme
  anahtarından geçer, böylece web siteleri indirme başlatamaz.

Kararlar için [DECISIONS.md](DECISIONS.md), elle denenecekler için
[TEST_CHECKLIST.md](TEST_CHECKLIST.md).

## Bilinen eksikler

- Video indirme Android'de yoktur, çünkü `yt-dlp` orada çalışmaz.
- Oturum gerektiren videolar indirilemez; çerezler aktarılmaz.
- Bir sayfada birden çok video varsa yalnızca ilki iner.
- Hız sınırı ve HTTP proxy torrent bağlantılarına uygulanmaz; proxy kullanmanız IP'nizi eşlerden gizlemez.
- Torrent motoru az bilinen bir kütüphanedir ve birçok hatası elle düzeltildi. Uzun süreli kullanımda
  sorun çıkarsa bir sonraki aday `libtorrent`'tir. Gerçek ağda yalnızca Debian torrenti ile denendi.
- Tamamlanan torrent paylaşılmaya (seed) devam etmez; biten torrent listede durur ama gönderim yapmaz.
- Masaüstünde tarayıcıdaki `magnet:` bağlantısına tıklamak uygulamayı açmaz; bağlantıyı yapıştırın veya
  eklentinin sağ tık menüsünü kullanın.
- BitTorrent v2 ve uTP denenmedi; bağlantılar TCP üzerindendir.
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

## Lisans

[MIT](LICENSE). `packages/third_party/dtorrent_task_v2` kendi BSD 3-Clause lisansıyla dağıtılır.
