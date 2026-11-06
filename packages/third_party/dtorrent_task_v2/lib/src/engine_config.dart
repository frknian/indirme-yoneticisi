/// Yerel yama: motorun isolate başına ayarları. Görev başlamadan önce atanır.
class TorrentEngineConfig {
  TorrentEngineConfig._();

  /// Yönlendiricide UPnP/NAT-PMP port yönlendirmesi açılsın mı?
  /// Ağ ayarını değiştirdiği için varsayılan olarak kapalıdır.
  static bool portForwarding = false;

  /// Gelen bağlantı portu; 0 işletim sistemine bırakır.
  static int listenPort = 0;

  /// Eşzamanlı eş bağlantısı üst sınırı.
  static int maxActivePeers = 50;

  /// Loopback eşlere izin verilsin mi? Yalnızca yerel testler içindir.
  static bool allowLoopbackPeers = false;

  /// DHT kullanılsın mı?
  static bool dht = true;
}
