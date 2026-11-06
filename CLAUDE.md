# İndirme Yöneticisi (IDM benzeri) – Claude Code Rehberi

## Proje özeti
Kendi internet indirme yöneticimizi geliştiriyoruz. Hedef platformlar: **Windows, macOS, Linux ve Android** (iOS en sona, isteğe bağlı). Tek kod tabanı: **Flutter (Dart)**.

Temel özellik: Sunucu `Accept-Ranges: bytes` destekliyorsa dosyayı N parçaya bölüp paralel indirmek, duraklat/devam et ve çökme sonrası kurtarma desteği sunmak.

## Mimari
Ortak çekirdek + platforma özel kabuk:

```
download_manager/
├── packages/
│   └── dm_core/            # Saf Dart paketi, UI'dan bağımsız (önce bu yazılır)
│       ├── lib/
│       │   ├── src/
│       │   │   ├── probe.dart          # HEAD ile boyut, Accept-Ranges, dosya adı tespiti
│       │   │   ├── segment.dart        # Parça modeli (başlangıç, bitiş, indirilen)
│       │   │   ├── downloader.dart     # Parçalı indirme, isolate yönetimi
│       │   │   ├── metadata_store.dart # .part + JSON metadata (kaydet/yükle)
│       │   │   ├── queue.dart          # İndirme kuyruğu, eşzamanlılık sınırı
│       │   │   ├── retry.dart          # Yeniden deneme / backoff
│       │   │   ├── speed_meter.dart    # Hız ve kalan süre hesabı
│       │   │   └── hash_verify.dart    # SHA-256 doğrulama
│       │   └── dm_core.dart
│       ├── bin/cli.dart                # Çekirdeği test etmek için komut satırı
│       └── test/
├── app/                    # Flutter uygulaması (masaüstü + Android)
└── extension/              # Chrome eklentisi (2. aşama, JS)
```

## Çekirdek motor kuralları
- İndirme başlamadan önce `HEAD` isteği at; `Content-Length` ve `Accept-Ranges` kontrol et.
- Range desteği yoksa veya boyut bilinmiyorsa **tek bağlantıya düş** (fallback).
- Her parça kendi isolate'ında `Range: bytes=start-end` ile indirilir; parça sayısı **ayarlanabilir** (varsayılan 8, üst sınır 16).
- İndirme sırasında `<dosya>.part` kullan; tamamlanınca yeniden adlandır. Metadata (`<dosya>.dmmeta`, JSON) her parçanın ilerlemesini periyodik olarak kaydeder.
- Duraklat/devam: metadata'dan oku, sadece eksik byte aralıklarını iste. Devam ederken sunucuda `ETag` / `Last-Modified` değişmişse indirmeyi baştan başlat.
- `429`, `503` ve bağlantı kopmalarında üstel geri çekilme (exponential backoff) ile yeniden dene; parça sayısını düşürmeyi dene.
- İlerleme ve durum bilgisini `Stream` ile yayınla (UI çekirdeğe sadece bu stream'lerle bağlanır).
- Çekirdek paketi `dart:io` dışında Flutter'a bağımlı **olmamalı**.
- Mümkünse hash (SHA-256) doğrulaması sun.

## Platforma özel notlar
| | Masaüstü | Android | iOS |
|---|---|---|---|
| Link yakalama | Chrome eklentisi + localhost HTTP sunucusu (veya native messaging) | Paylaş menüsü / link intent'i | Share extension |
| Arka plan | Sorun yok | Foreground service + bildirim (zorunlu) | Çok kısıtlı (URLSession) |

- Android 13+: bildirim izni gerekir. Depolama için Scoped Storage / `MediaStore` kurallarına uy.
- iOS uzun süreli arka plan indirmeye izin vermez; en sona bırak.
- Arayüz ekran boyutuna göre uyarlanır: masaüstünde liste + yan panel, mobilde tek sütun.

## Yol haritası
1. [x] `dm_core`: HEAD probe + tek bağlantılı indirme + ilerleme stream'i
2. [x] Çok parçalı indirme (isolate'lar) + birleştirme
3. [x] Metadata ile duraklat/devam + çökme sonrası kurtarma
4. [x] Kuyruk, yeniden deneme, hız/kalan süre, hash doğrulama
5. [x] CLI ile uçtan uca test
6. [x] Flutter UI (Android + masaüstü)
7. [x] Android foreground service + paylaşım intent'i
8. [x] Masaüstü için Chrome eklentisi
9. [ ] (İsteğe bağlı) iOS, cihazlar arası liste senkronu, HLS/DASH için ffmpeg/yt-dlp entegrasyonu

## Kod standartları
- Dart null-safety, `dart format` ve `dart analyze` temiz olmalı.
- Çekirdek için birim testleri yaz; ağ katmanını test için yerel bir HTTP sunucusuyla (Range destekli) doğrula.
- Hata durumları açık tiplerle ifade edilir (örn. `DownloadException` alt sınıfları); sessizce yutma.
- Ağ ve disk işlemleri UI isolate'ını bloklamamalı.
- Yorumlar ve commit mesajları Türkçe veya İngilizce olabilir, tutarlı kal.

## Çalışma şekli (Claude için)
**Tüm işi tek seferde, durmadan bitir.** Yol haritasındaki 1-8. adımların hepsini bu oturumda sırayla tamamla. Adımlar arasında onay isteme, "devam edeyim mi?" diye sorma.

- Önce çekirdek paketini bitir; UI'ya geçmeden CLI ile test et.
- Her adımdan sonra proje `dart analyze` ve testlerden temiz geçen, çalıştırılabilir bir durumda olsun; ancak o zaman sonrakine geç.
- Belirsiz bir karar çıkarsa kendin makul bir seçim yap, bunu `DECISIONS.md` dosyasına tek satırla not et ve devam et. Sadece geri döndürülemez/kritik bir engel varsa dur.
- Yeni bağımlılıklar için tercih: `http` veya `dio`, `crypto`, `path`, `path_provider`, `provider` veya `riverpod`. Gerekçeyi `DECISIONS.md`'ye yaz.
- Yol haritasındaki maddeleri bitirdikçe `[x]` ile işaretle.
- Bu ortamda gerçek cihaz/emülatör ya da Chrome ile elle test yapılamayan kısımlar (Android foreground service, eklenti) için kodu yaz, derlemeyi/analizi doğrula ve `TEST_CHECKLIST.md` dosyasına kullanıcının elle deneyeceği adımları yaz.
- iOS ve 9. adım kapsam dışı; dokunma.

## Bitti tanımı (Definition of Done)
1. `packages/dm_core` testleri geçiyor (yerel Range destekli test sunucusuyla: çok parçalı indirme, duraklat/devam, kopma sonrası kurtarma, Range desteklemeyen sunucuda fallback).
2. `dart run bin/cli.dart <url>` ile gerçek bir dosya parçalı indirilebiliyor.
3. Flutter uygulaması masaüstü ve Android için `flutter analyze` temiz ve derleniyor: indirme ekle, liste, ilerleme, hız, duraklat/devam, iptal, ayarlar (parça sayısı, indirme klasörü).
4. Android: foreground service, bildirim izni, paylaş/link intent'i ile indirme başlatma.
5. Masaüstü: localhost HTTP sunucusu + Chrome eklentisi (Manifest V3) ile link yakalama.
6. `README.md` (kurulum, çalıştırma, mimari özeti), `DECISIONS.md`, `TEST_CHECKLIST.md` yazılmış.
7. Son çıktıda: ne yapıldı, ne elle test edilmeli, bilinen eksikler kısa liste halinde.

## Hukuki / etik not
Genel dosya indirme serbesttir. Telifli içerik indirme sorumluluğu kullanıcıya aittir; uygulama DRM korumasını aşmaya çalışmaz.
