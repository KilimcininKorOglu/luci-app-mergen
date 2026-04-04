# Mergen

OpenWrt için ASN/IP tabanlı politika yönlendirme servisi. ASN prefix listelerini otomatik olarak çözer ve trafiği belirlenen ağ arayüzlerine yönlendirmek için `ip rule`/`ip route` kuralları oluşturur.

Mergen, O(1) karmaşıklıkla paket eşleştirme için nftables set'leri kullanır; eski sistemlerde otomatik olarak ipset'e geri döner.

[English](README.en.md)

## Özellikler

- **ASN tabanlı yönlendirme** -- Otonom Sistem Numarasına göre trafik yönlendirme (örneğin tüm Cloudflare trafiğini WAN2 üzerinden gönder)
- **IP/CIDR yönlendirme** -- Doğrudan prefix tabanlı politika yönlendirme kuralları
- **DNS tabanlı yönlendirme** -- dnsmasq nftset/ipset entegrasyonu ile alan adına göre yönlendirme
- **Ülke tabanlı yönlendirme** -- RIR delegated istatistikleri ile ülke koduna göre yönlendirme
- **Çoklu sağlayıcı** -- Otomatik geri dönüş ve sağlık takibi ile 6 veri sağlayıcısı
- **IPv6 çift yığın** -- Ayrı v4/v6 set yönetimi ile tam IPv4 ve IPv6 desteği
- **Güvenli mod** -- Bağlantı kaybı durumunda otomatik geri alma ile atomik uygulama
- **LuCI web arayüzü** -- Kural yönetimi, izleme ve yapılandırma için 7 sayfalı web arayüzü
- **mwan3 entegrasyonu** -- mwan3 yük dengeleyici ile birlikte çift mod çalışma
- **İçeri/dışarı aktarma** -- JSON tabanlı kural yedekleme ve geri yükleme
- **Nöbetçi (Watchdog)** -- Arayüz yedeklemesi ile sürekli sağlık izleme

## Gereksinimler

| Gereksinim       | Minimum                                   |
|------------------|-------------------------------------------|
| OpenWrt sürümü   | 23.05 veya sonrası                        |
| Güvenlik duvarı  | nftables (varsayılan) veya iptables/ipset |
| Disk alanı       | ~500 KB                                   |
| RAM              | 32 MB veya fazlası                        |

## Kurulum

### IPK paketlerinden

En son sürümü indirin ve yönlendiricinize kurun:

```sh
scp mergen_*.ipk luci-app-mergen_*.ipk root@<router>:/tmp/
ssh root@<router>
opkg install /tmp/mergen_*.ipk
opkg install /tmp/luci-app-mergen_*.ipk    # isteğe bağlı: web arayüzü
```

### Kaynaktan derleme (OpenWrt buildroot)

```sh
cd /path/to/openwrt
git clone https://github.com/KilimcininKorOglu/luci-app-mergen.git package/mergen
make menuconfig    # Network > Routing and Redirection > mergen seçin
make package/mergen/compile
```

## Hızlı Başlangıç

```sh
# Servisi etkinleştir
uci set mergen.global.enabled='1'
uci commit mergen
/etc/init.d/mergen enable
/etc/init.d/mergen start

# Kural ekle: Cloudflare (AS13335) trafiğini wan2 üzerinden yönlendir
mergen add --name cloudflare --asn 13335 --via wan2

# Tüm kuralları uygula
mergen apply

# Durumu kontrol et
mergen status
```

## CLI Komutları

```
mergen add          Yeni yönlendirme kuralı ekle
mergen remove       Kuralı ada göre kaldır
mergen list         Tüm yapılandırılmış kuralları listele
mergen show         Detaylı kural bilgisi göster
mergen enable       Devre dışı kuralı etkinleştir
mergen disable      Kuralı kaldırmadan devre dışı bırak
mergen apply        Prefixleri çöz ve yönlendirmeyi uygula
mergen flush        Tüm aktif rotaları kaldır
mergen rollback     Önceki yönlendirme durumuna geri dön
mergen confirm      Güvenli mod sonrası değişiklikleri onayla
mergen status       Servis ve yönlendirme durumunu göster
mergen diag         Tanı komutlarını çalıştır
mergen log          Servis kayıtlarını görüntüle
mergen validate     Yapılandırmayı doğrula
mergen tag          Kurallara etiket ekle/kaldır
mergen update       Prefix önbelleğini yenile
mergen import       JSON'dan kural içe aktar
mergen export       Kuralları JSON'a dışa aktar
mergen resolve      ASN/IP çöz (uygulamadan)
mergen version      Sürüm bilgisini göster
mergen help         Yardım metnini göster
```

Tüm komutların bayrak ve örneklerle tam dokümantasyonu için [docs/cli-reference.md](docs/cli-reference.md) dosyasına bakın.

## Yapılandırma

Tüm yapılandırma UCI üzerinden `/etc/config/mergen` dosyasında yönetilir:

```
config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option default_table '100'
    option ipv6_enabled '1'
    option watchdog_enabled '1'
    option mode 'standalone'

config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wan2'
    option enabled '1'

config provider 'ripe'
    option enabled '1'
    option priority '10'
```

Tam yapılandırma referansı için [docs/configuration.md](docs/configuration.md) dosyasına bakın.

## Veri Sağlayıcıları

| Sağlayıcı | Kaynak                     | Tür        | Varsayılan |
|------------|----------------------------|------------|------------|
| RIPE Stat  | stat.ripe.net              | API        | Etkin      |
| bgp.tools  | bgp.tools                  | API        | Etkin      |
| bgpview.io | bgpview.io                 | API        | Devre dışı |
| MaxMind    | GeoLite2 ASN veritabanı    | Çevrimdışı | Devre dışı |
| RouteViews | MRT dump arşivleri         | Çevrimdışı | Devre dışı |
| IRR/RADB   | whois.radb.net             | Whois      | Devre dışı |

Sağlayıcılar öncelik sırasına göre sorgulanır, başarısızlık durumunda otomatik geri dönüş yapılır.

## LuCI Web Arayüzü

İsteğe bağlı `luci-app-mergen` paketi, **Services > Mergen** altında aşağıdaki sayfalarla bir web arayüzü sağlar:

- **Genel Bakış** -- Servis durumu, aktif kurallar ve trafik istatistikleri
- **Kurallar** -- Sürükle-bırak sıralama, toplu işlemler ve JSON dışa aktarımlı CRUD yönetimi
- **ASN Tarayıcı** -- ASN prefix listelerini ara ve karşılaştır, hızlı kural ekleme
- **Sağlayıcılar** -- Sağlayıcı sağlık durumu, bağlantı testi, önbellek yönetimi
- **Arayüzler** -- Ağ arayüzü durumu ve ping tanılama
- **Kayıtlar** -- Seviye ve metin filtreli canlı kayıt görüntüleyici
- **Gelişmiş** -- Motor ayarları, IPv6, performans, güvenlik, bakım

Tam web arayüzü kılavuzu için [docs/luci-guide.md](docs/luci-guide.md) dosyasına bakın.

## IPK Paketleri Oluşturma

OpenWrt SDK'sı olmadan bağımsız IPK paketleri oluşturun:

```sh
./build.sh
```

Çıktı:
```
dist/mergen_0.1.0-N_all.ipk
dist/luci-app-mergen_0.1.0-N_all.ipk
```

Derleme numarası `N`, git commit sayısından türetilir.

## Dokümantasyon

| Belge                                              | Açıklama                          |
|----------------------------------------------------|-----------------------------------|
| [docs/install.md](docs/install.md)                 | Kurulum ve yükseltme kılavuzu    |
| [docs/configuration.md](docs/configuration.md)     | UCI yapılandırma referansı        |
| [docs/cli-reference.md](docs/cli-reference.md)     | CLI komut referansı               |
| [docs/luci-guide.md](docs/luci-guide.md)           | LuCI web arayüzü kılavuzu        |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Tanı ve sorun giderme             |

## Proje Yapısı

```
mergen/                          Servis paketi
  files/usr/bin/mergen           CLI aracı
  files/usr/sbin/mergen-watchdog Nöbetçi servisi
  files/usr/lib/mergen/          Kabuk kütüphane modülleri
  files/etc/config/mergen        UCI yapılandırması
  files/etc/init.d/mergen        procd servis betiği
  files/etc/mergen/providers/    Veri sağlayıcı betikleri
  tests/                         Test paketleri (shunit2)

luci-app-mergen/                 Web arayüzü paketi
  luasrc/controller/             LuCI denetleyici ve RPC
  luasrc/model/cbi/              CBI form modelleri
  luasrc/view/mergen/            HTM görünüm şablonları
  htdocs/luci-static/mergen/     CSS ve JavaScript
  po/                            Çeviriler (en, tr)
```

## Lisans

[MIT](LICENSE)
