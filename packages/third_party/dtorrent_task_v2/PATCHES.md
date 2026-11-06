# Yerel yamalar (0.5.4 üzerine)

Kaynak: https://github.com/atlet99/dtorrent_task_v2 (BSD 3-Clause, `LICENSE`).

1. `api.ipify.org` çağrıları ve `dart_ipify` bağımlılığı kaldırıldı (`peers_manager.dart`,
   `metadata_downloader.dart`): kullanıcının IP'si üçüncü tarafa sorulmaz.
2. Torrent dosya yolları doğrulanır (`assertSafeTorrentPath`, `download_file_manager.dart`):
   `../`, mutlak yol, ters bölü ve sürücü harfi indirme klasöründen çıkamaz.
3. `test`, `example`, `bin` klasörleri depo boyutu için çıkarıldı.
4. Torrent içindeki sembolik bağlantılar oluşturulmaz ve dosyalara çalıştırma izni verilmez.
5. `TorrentEngineConfig`: UPnP/NAT-PMP varsayılan kapalı (motor yönlendiricide kalıcı kayıt bırakıyordu); dinleme portu, eş sınırı ve DHT ayarlanabilir.
6. Info-hash ham `info` baytlarından hesaplanır (`_extractInfoDictBytes`): özgün kod gerçek torrentlerde yanlış özet üretiyor, izleyiciler torrenti tanımıyordu.
7. Eş sınırı `addNewPeerAddress` içinde de uygulanır (özgün kodda 300+ bağlantı açılıyordu); DHT kapatılabilir.
8. BEP 10 kimlik eşlemesi düzeltildi (`extended_processor.dart`): gelen mesajlar yerel kimliklerle çözülür. Özgün kodda PEX mesajları `ut_metadata` sanılıyor, magnet bağlantıları hiç tamamlanmıyordu. Metadata aşamasına da eş sınırı eklendi.
9. Metadata isteklerinde yanıtsız eş sıranın sonuna alınır, kopan eş listeden çıkarılır (özgün kod hep aynı eşlere soruyordu).
10. Metadata önbelleği geçici klasöre yazılmaz; indirilen torrentlerin kaydı iz bırakmaz.
11. Kapalı dosya yeniden açılmaz, `close()` açık tanıtıcıyı daima kapatır (Windows'ta dosya kilitli kalıyordu).
12. LSD gönderimi sınırlı denenir ve LSD hataları başlatmayı engellemez (çoklu yayın engelli ağda görev hiç başlamıyordu).
13. Dosya açma ve oluşturma tek seferlik yapıldı: eşzamanlı `??= await` tanıtıcı sızdırıyor (Windows'ta dosya kilitli kalıyordu) ve `FileMode.write` yazılmış veriyi silebiliyordu.
