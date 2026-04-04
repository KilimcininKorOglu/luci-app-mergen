# Mergen Yapılandırma Referansı

[English](configuration.en.md)

Mergen, standart OpenWrt UCI (Unified Configuration Interface) sistemini kullanır.
Tüm yapılandırma tek bir dosyada bulunur:

```
/etc/config/mergen
```

Bu belge, yapılandırılabilir tüm bölüm ve seçenekleri kapsar.

---

## 1. Genel Bölüm

Genel bölüm; daemon davranışını, motor seçimini, güvenlik mekanizmalarını
ve kaynak limitlerini kontrol eder. Tam olarak bir adet genel bölüm bulunur.

```uci
config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option update_interval '86400'
    option default_table '100'
    option ipv6_enabled '1'
    option packet_engine 'auto'
    option mode 'standalone'
    option max_prefix_per_rule '10000'
    option max_prefix_total '50000'
    option watchdog_enabled '1'
    option watchdog_interval '60'
    option safe_mode_ping_target '8.8.8.8'
    option fallback_strategy 'sequential'
    option config_version '1'
```

### Seçenek Referansı

| Seçenek                 | Tip     | Varsayılan     | Açıklama                                                                          |
|-------------------------|---------|----------------|-----------------------------------------------------------------------------------|
| `enabled`               | boolean | `0`            | Ana anahtar. Mergen'i etkinleştirmek için `1` olarak ayarlayın.                   |
| `log_level`             | enum    | `info`         | Loglama ayrıntısı. Seçenekler: `debug`, `info`, `warning`, `error`.              |
| `update_interval`       | integer | `86400`        | Otomatik prefix listesi yenileme aralığı (saniye cinsinden, 86400 = 24 saat).    |
| `default_table`         | integer | `100`          | Temel yönlendirme tablo numarası. Her kural bu değerden başlayan bir tablo alır.  |
| `ipv6_enabled`          | boolean | `1`            | IPv6 prefix çözümlemesi ve yönlendirmeyi etkinleştirir. Yalnızca IPv4 için `0`.   |
| `packet_engine`         | enum    | `auto`         | Paket eşleştirme motoru. Seçenekler: `auto`, `nftables`, `ipset`.                |
| `mode`                  | enum    | `standalone`   | Çalışma modu. `standalone` rotaları doğrudan yönetir; `mwan3` mwan3 ile entegre olur. |
| `max_prefix_per_rule`   | integer | `10000`        | Tek bir kuralın içerebileceği maksimum prefix sayısı.                             |
| `max_prefix_total`      | integer | `50000`        | Tüm kurallardaki toplam maksimum prefix sayısı.                                  |
| `watchdog_enabled`      | boolean | `1`            | Hotplug olayları ve periyodik güncellemeler için watchdog daemon'unu etkinleştirir.|
| `watchdog_interval`     | integer | `60`           | Watchdog yoklama aralığı (saniye cinsinden).                                     |
| `safe_mode_ping_target` | IP      | `8.8.8.8`      | `mergen apply --safe` sonrası bağlantı doğrulaması için hedef IP.                |
| `fallback_strategy`     | enum    | `sequential`   | Yedek arayüzlerin denenme şekli. Şu anda yalnızca `sequential` desteklenir.      |
| `config_version`        | integer | `1`            | Mergen sürümleri arası yapılandırma taşıma için şema sürümü.                     |

### `packet_engine` Hakkında Notlar

- **auto** -- Mergen, çalışma zamanında mevcut araçları algılar. OpenWrt 23.05+ üzerinde nftables tercih edilir,
  eski kurulumlarda ipset'e geri döner.
- **nftables** -- nftables setlerini zorlar. `nft` kurulu değilse başarısız olur.
- **ipset** -- Eski ipset kullanımını zorlar. `ipset` kurulu değilse başarısız olur.

### `mode` Hakkında Notlar

- **standalone** -- Mergen, ayrılmış yönlendirme tablolarında kendi `ip rule` ve `ip route`
  girişleri oluşturur ve yönetir.
- **mwan3** -- Mergen, mwan3 politikalarıyla uyumlu kurallar üretir. mwan3'un ayrı olarak
  kurulmuş ve yapılandırılmış olması gerekir.

---

## 2. Kural Bölümleri

Her `config rule` bloğu, tek bir yönlendirme politikası tanımlar. Kurallar isimsiz UCI bölümleridir
(anonim) ve dahili olarak benzersiz olması gereken `name` seçeneğiyle tanımlanır.

```uci
config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wg0'
    option priority '100'
    option enabled '1'
    option fallback 'wan'
    list tag 'vpn'
```

### Seçenek Referansı

| Seçenek    | Tip     | Zorunlu | Varsayılan | Açıklama                                                              |
|------------|---------|---------|------------|-----------------------------------------------------------------------|
| `name`     | string  | evet    | --         | Benzersiz kural tanımlayıcısı. Yalnızca alfanumerik, tire ve alt çizgi. |
| `via`      | string  | evet    | --         | Hedef çıkış arayüzü (örneğin `wg0`, `wan`, `eth1`).                  |
| `priority` | integer | hayır   | `100`      | Yönlendirme önceliği. Aralık: 1--32000. Düşük değerler önce işlenir. |
| `enabled`  | boolean | hayır   | `1`        | Kuralı kaldırmadan devre dışı bırakmak için `0` olarak ayarlayın.    |
| `fallback` | string  | hayır   | --         | Yedek arayüz. `via` düşerse trafik buraya yönlendirilir.             |
| `tag`      | list    | hayır   | --         | Gruplama ve toplu işlemler için bir veya daha fazla etiket.           |

### Hedef Seçenekleri (birbirini dışlar)

Her kuralda aşağıdaki hedef seçeneklerinden tam olarak biri ayarlanmalıdır. Birden fazla değer için
`option` yerine `list` sözdizimi kullanın.

| Seçenek   | Tip           | Açıklama                                                          |
|-----------|---------------|-------------------------------------------------------------------|
| `asn`     | integer/list  | Bir veya daha fazla Otonom Sistem Numarası (örneğin `13335`).     |
| `ip`      | CIDR/list     | Bir veya daha fazla IP/CIDR bloğu (örneğin `185.70.40.0/22`).    |
| `domain`  | string/list   | DNS tabanlı yönlendirme için bir veya daha fazla alan adı.        |
| `country` | string/list   | Bir veya daha fazla ISO 3166-1 alpha-2 ülke kodu (örneğin `TR`, `US`). |

**Tek hedef** için `option`, **birden fazla hedef** için `list` kullanılır:

```uci
# Tek ASN
config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wg0'

# Birden fazla ASN
config rule
    option name 'google'
    list asn '15169'
    list asn '36040'
    option via 'wg0'

# Birden fazla IP bloğu
config rule
    option name 'office-network'
    list ip '10.0.0.0/8'
    list ip '172.16.0.0/12'
    option via 'lan'
```

---

## 3. Sağlayıcı Bölümleri

Sağlayıcı bölümleri, ASN çözümleme veri kaynaklarını yapılandırır. Mergen, etkin sağlayıcıları
öncelik sırasına göre (en düşük numara önce) sorgular ve ilk başarılı sonucu kullanır.

```uci
config provider 'ripe'
    option enabled '1'
    option priority '10'
    option api_url 'https://stat.ripe.net/data/announced-prefixes/data.json'
    option timeout '30'

config provider 'bgptools'
    option enabled '1'
    option priority '20'
    option api_url 'https://bgp.tools/table.jsonl'
    option timeout '30'

config provider 'maxmind'
    option enabled '0'
    option priority '30'
    option db_path '/usr/share/mergen/GeoLite2-ASN.mmdb'
```

### Seçenek Referansı

| Seçenek    | Tip     | Zorunlu | Varsayılan | Açıklama                                                              |
|------------|---------|---------|------------|-----------------------------------------------------------------------|
| `enabled`  | boolean | hayır   | `0`        | Sağlayıcıyı etkinleştirmek için `1` olarak ayarlayın.               |
| `priority` | integer | hayır   | `99`       | Çözümleme sırası. Düşük değerler önce sorgulanır.                    |
| `api_url`  | string  | hayır   | --         | API ucu URL'si. Ağ tabanlı sağlayıcılar için gereklidir.            |
| `timeout`  | integer | hayır   | `30`       | API istek zaman aşımı (saniye cinsinden).                            |
| `db_path`  | string  | hayır   | --         | Yerel veritabanı dosya yolu. MaxMind gibi çevrimdışı sağlayıcılar için. |

### Mevcut Sağlayıcılar

| Bölüm ID     | Kaynak               | Notlar                                                  |
|--------------|----------------------|---------------------------------------------------------|
| `ripe`       | RIPE Stat API        | Resmi RIR verisi. İstek hızı sınırlamasına tabidir.     |
| `bgptools`   | bgp.tools            | Hızlı, kapsamlı BGP tablo verisi.                       |
| `bgpview`    | bgpview.io           | Basit REST API. İstek hızı sınırlamasına tabidir.       |
| `maxmind`    | MaxMind GeoLite2     | Çevrimdışı ASN veritabanı. Periyodik indirme gerektirir.|
| `routeviews` | RouteViews           | Tam MRT/RIB dökümleri. En kapsamlı ama ağır.            |
| `irr`        | IRR / RADB           | Yönlendirme sicillerine karşı whois tabanlı sorgular.   |

Bir sağlayıcı başarısız olduğunda (zaman aşımı, HTTP hatası, boş yanıt), Mergen otomatik olarak
`fallback_strategy` ayarına göre sıradaki etkin sağlayıcıyı dener.

---

## 4. Örnek Yapılandırmalar

### 4.1 VPN Bölünmüş Yönlendirme

Belirli hizmetleri bir WireGuard tüneli üzerinden yönlendirirken varsayılan trafiği
birincil WAN arayüzünde tutun.

```uci
config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option update_interval '86400'
    option default_table '100'
    option ipv6_enabled '1'
    option packet_engine 'auto'
    option mode 'standalone'
    option watchdog_enabled '1'
    option safe_mode_ping_target '8.8.8.8'
    option fallback_strategy 'sequential'
    option config_version '1'

config provider 'ripe'
    option enabled '1'
    option priority '10'
    option api_url 'https://stat.ripe.net/data/announced-prefixes/data.json'
    option timeout '30'

config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wg0'
    option priority '100'
    option enabled '1'
    option fallback 'wan'
    list tag 'vpn'

config rule
    option name 'google'
    list asn '15169'
    list asn '36040'
    option via 'wg0'
    option priority '200'
    option enabled '1'
    option fallback 'wan'
    list tag 'vpn'

config rule
    option name 'protonmail'
    option ip '185.70.40.0/22'
    option via 'wg0'
    option priority '300'
    option enabled '1'
    list tag 'vpn'
```

Eşdeğer CLI komutları:

```sh
mergen add --name cloudflare --asn 13335 --via wg0 --fallback wan
mergen add --name google --asn 15169,36040 --via wg0 --fallback wan
mergen add --name protonmail --ip 185.70.40.0/22 --via wg0
mergen apply
```

### 4.2 Ülke Tabanlı Yönlendirme

Yurt içi trafiği birincil WAN bağlantısında tutun ve geri kalan her şeyi
bir VPN üzerinden yönlendirin.

```uci
config rule
    option name 'domestic-direct'
    option country 'TR'
    option via 'wan'
    option priority '100'
    option enabled '1'
    list tag 'geo'
```

Eşdeğer CLI komutu:

```sh
mergen add --name domestic-direct --country TR --via wan
mergen apply
```

Varsayılan bir VPN rotasıyla birleştirildiğinde (Mergen dışında işletim sistemi seviyesinde yapılandırılır),
bu, çözümlenen tüm Türkiye ASN prefix'lerinin tüneli atlamasını sağlar.

### 4.3 DNS Tabanlı Yönlendirme

Belirli alan adlarına yönelik trafiği, dnsmasq nftset/ipset entegrasyonu kullanarak
belirlenmiş bir arayüz üzerinden yönlendirin.

```uci
config rule
    option name 'streaming'
    list domain 'netflix.com'
    list domain 'hulu.com'
    list domain 'disneyplus.com'
    option via 'wg0'
    option priority '150'
    option enabled '1'
    list tag 'media'
```

Eşdeğer CLI komutu:

```sh
mergen add --name streaming --domain netflix.com,hulu.com,disneyplus.com --via wg0
mergen apply
```

DNS tabanlı kurallar, dnsmasq yapılandırmasına nftset veya ipset direktifleri ekleyerek çalışır.
Çözümlenen IP adresleri, DNS sorguları gerçekleştikçe dinamik olarak ilgili sete eklenir.

### 4.4 Çoklu WAN ve Yedekleme

Trafiği iki WAN bağlantısı arasında bölerek, bir arayüz düşerse otomatik
yedekleme sağlama.

```uci
config mergen 'global'
    option enabled '1'
    option mode 'standalone'
    option watchdog_enabled '1'
    option watchdog_interval '30'
    option fallback_strategy 'sequential'
    option config_version '1'

config rule
    option name 'work-traffic'
    option asn '8075'
    option via 'wan_fiber'
    option priority '100'
    option enabled '1'
    option fallback 'wan_lte'
    list tag 'work'

config rule
    option name 'cdn-traffic'
    list asn '13335'
    list asn '16509'
    option via 'wan_lte'
    option priority '200'
    option enabled '1'
    option fallback 'wan_fiber'
    list tag 'cdn'
```

`wan_fiber` düşerse, watchdog hotplug aracılığıyla arayüz durum değişikliğini algılar
ve `work-traffic` trafiğini `wan_lte` üzerinden yönlendirir. `wan_fiber`
tekrar devreye girdiğinde, trafik otomatik olarak geri taşınır.

---

## 5. Dosya Konumları

| Yol                         | Açıklama                                             |
|-----------------------------|------------------------------------------------------|
| `/etc/config/mergen`        | UCI yapılandırma dosyası (izinler: 0600)             |
| `/tmp/mergen/cache/`        | Önbelleğlenmiş ASN prefix listeleri                  |
| `/tmp/mergen/status.json`   | Çalışma zamanı durumu (watchdog durumu, kural sayıları) |
| `/var/lock/mergen.lock`     | Eşanlı erişim kontrolü için işlem kilidi             |
| `/etc/mergen/providers/`    | Sağlayıcı eklenti betikleri                          |
| `/etc/mergen/rules.d/`      | JSON kural içeri aktarma dosyaları için dizin         |
| `/usr/lib/mergen/`          | Çekirdek kütüphane modülleri                         |
| `/usr/bin/mergen`           | CLI uygulaması                                       |
| `/usr/sbin/mergen-watchdog` | Watchdog daemon'u                                    |

---

## 6. Değişikliklerin Uygulanması

`/etc/config/mergen` dosyasını doğrudan veya `uci` komutları aracılığıyla düzenlemek
yönlendirme kurallarını etkinleştirmez. Herhangi bir yapılandırma değişikliğinden sonra şu komutu çalıştırın:

```sh
mergen apply
```

Bağlantı kesilmesi durumunda otomatik geri alma ile güvenli uygulama için:

```sh
mergen apply --safe
```

Güvenli mod, kuralları uyguladıktan sonra `safe_mode_ping_target` adresine ping atarak
bağlantıyı doğrular. Ping 60 saniye içinde başarısız olursa, tüm değişiklikler otomatik olarak geri alınır.

Yapılandırmayı uygulamadan doğrulamak için:

```sh
mergen validate
```
