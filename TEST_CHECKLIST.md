# Elle test listesi

Yalnızca otomatik olarak veya bu oturumda doğrulanamayanlar listelenmiştir.

## Chrome eklentisi (gerçek Chrome'da hiç yüklenmedi)

Eklenti mantığı Node'da sahte `chrome` nesnesiyle, sunucu tarafı ise gerçek uygulamaya
`lib.js` ile istek atılarak denendi.

- [ ] `extension` klasörünü paketlenmemiş olarak yükleyin; hata görünmemeli ve ayarlar sayfası açılmalı.
- [ ] Uygulamadaki anahtarı yapıştırıp **Kaydet ve dene**'ye basın: "Uygulamaya bağlı" yazmalı.
- [ ] Yanlış anahtar girin: "Anahtar yanlış" yazmalı.
- [ ] Bir dosya indirin: uygulamada görünmeli, Chrome'daki indirme kaybolmalı.
- [ ] Uygulamayı kapatıp dosya indirin: indirme Chrome'da normal sürmeli.
- [ ] Bir linke sağ tıklayıp **İndirme Yöneticisi ile indir**'i seçin.
- [ ] Açılır pencereden devralmayı kapatın: indirmeler Chrome'da kalmalı.
- [ ] Oturum gerektiren bir sitede devralmayı deneyin; bilinen eksik nedeniyle başarısız olabilir, hata metni anlaşılır olmalı.

## macOS arayüzü (ekran görüntüsü alınamadı)

Uygulama çalıştırıldı; yakalama, indirme ve `kill -9` kurtarması doğrulandı, ancak pencere görülmedi.
Aynı Flutter arayüzü Android emülatöründe görsel olarak kontrol edildi.

- [ ] Geniş pencerede listeden bir öğe seçin: yan panel ve parça çubuğu görünmeli.
- [ ] Pencereyi daraltın: tek sütuna geçmeli.
- [ ] **Ayarlar > İndirme klasörü** seçicisi açılmalı ve seçilen klasöre indirme yapılmalı.
- [ ] **Ayarlar**'daki yakalama bölümü: portu değiştirin, anahtarı yenileyin, eski anahtarın reddedildiğini görün.
- [ ] Duraklat, devam, iptal ve listeden kaldır (**Dosyayı da sil** dahil) düğmeleri.
- [ ] **Klasörde göster** Finder'ı açmalı.
- [ ] Cmd+Q ile kapatıp yeniden açın: sürmekte olan indirme devam etmeli.

## Windows ve Linux (derlenmedi)

Bu derlemeler macOS'ta yapılamaz. Kod ortak olduğundan yalnızca statik analizden geçti.

- [ ] `flutter build windows` ve `flutter build linux` başarılı olmalı.
- [ ] Uygulamayı açıp bir dosya indirin, duraklatıp devam edin.
- [ ] Windows: çalışan indirmede `.part` dosyası kilit sorunu çıkarmamalı, son ada taşınmalı.
- [ ] Windows: Güvenlik Duvarı `127.0.0.1` için uyarı vermemeli.
- [ ] **Klasörde göster** doğru çalışmalı.

## Android (Android 16 emülatöründe doğrulandı, gerçek cihazda denenmedi)

- [ ] Gerçek telefonda ekran kapalı ve Wi-Fi'da uzun indirme (uyku davranışı).
- [ ] Üretici pil kısıtlaması olan bir cihaz (Samsung, Xiaomi): servis ayakta kalmalı.
- [ ] Bir tarayıcıdan Paylaş menüsüyle gerçek link gönderin.
- [ ] Bildirim iznini reddedin: indirme yine sürmeli, uygulama çökmemeli.
- [ ] Android 15+: `dataSync` süresi dolunca indirmeler duraklatılmalı.
- [ ] Android 9 veya altı: dosya uygulama klasöründe kalmalı, liste doğru görünmeli.
- [ ] Depolama dolu iken: "Diskte yer kalmadı" hatası görünmeli.
- [ ] Bildirimden açma: mevcut ekran görünmeli, yeni kopya açılmamalı.

## Bağlantı ayarları ve logo

- [ ] **Ayarlar > Bağlantı**: hız sınırı girip indirme hızının sınırı aştığını kontrol edin.
- [ ] Gerçek bir HTTP proxy ile HTTPS dosyası indirin (testler yalnızca HTTP proxy'yi kapsıyor).
- [ ] Geçersiz proxy yazın: "sunucu:port biçiminde olmalı" görünmeli.
- [ ] macOS Dock, Windows görev çubuğu ve Android ana ekranında yeni ikonu kontrol edin.
