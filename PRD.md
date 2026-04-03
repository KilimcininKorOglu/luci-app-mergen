# Mergen - OpenWrt ASN/IP Bazlı Policy Routing

version: 1.0

> *Mergen: Türk-Altay mitolojisinde bilgelik ve okçuluk tanrısı. Oku daima hedefe ulaştırır.*

## 1. Problem Tanımı

OpenWrt kullanıcıları belirli hedeflere (ASN, IP blokları) giden trafiği farklı arayüzler üzerinden yönlendirmek ister. Örneğin:

- Belirli servislerin (Netflix, Cloudflare, Steam) trafiğini VPN üzerinden geçirmek
- İş trafiğini ana WAN'dan, eğlence trafiğini ikincil WAN'dan göndermek
- Ülke bazlı veya servis bazlı trafik ayırma

Mevcut çözümler:

| Çözüm               | Sorun                                            |
|---------------------|--------------------------------------------------|
| Manuel ip route     | ASN prefix listeleri sürekli değişir, bakımı zor |
| pbr paketi          | ASN desteği yok, sadece IP/CIDR bazlı            |
| mwan3               | ASN entegrasyonu yok, kurallar elle yazılır      |
| VPN provider script | Vendor'a bağımlı, genel amaçlı değil             |

**Mergen** bu boşlukları tek bir araçta kapatır: ASN numarası ver, geri kalanını o halleder.

## 2. Vizyon

```
mergen add --asn 13335 --via vpn0          # Cloudflare -> VPN
mergen add --asn 32934 --via wan2          # Facebook -> WAN2
mergen add --ip 10.0.0.0/8 --via lan       # Dahili trafik -> LAN
mergen apply                                # Kuralları uygula
```

Tek komutla ASN'in tüm prefix'lerini çözümleyip, ip rule + ip route + nftables/ipset kurallarına dönüştüren, OpenWrt-native bir policy routing daemon'u.

## 3. Hedefler

### 3.1 Birincil Hedefler

- **ASN-to-Route**: ASN numarasından prefix listesini otomatik çözümle ve routing kuralı oluştur
- **IP/CIDR-to-Route**: Manuel IP/CIDR blokları için doğrudan routing kuralı oluştur
- **Multi-WAN Desteği**: Trafiği farklı WAN arayüzlerine yönlendir (mwan3 entegrasyonu veya standalone)
- **VPN Desteği**: Trafiği WireGuard, OpenVPN veya diğer VPN tünellerine yönlendir
- **LuCI Entegrasyonu**: Web panelinden kural yönetimi, durum izleme
- **Otomatik Güncelleme**: Prefix listelerini periyodik olarak güncelle (cron)

### 3.2 İkincil Hedefler

- **DNS Bazlı Routing**: Domain bazlı kurallar (opsiyonel, DNSMASQ ipset/nftset entegrasyonu)
- **Ülke Bazlı Routing**: Ülke koduna göre tüm ASN'leri toplu ekle
- **Trafik İstatistikleri**: Kural başına trafik sayaçları
- **Failover**: Hedef arayüz düşerse otomatik geri dönüş

## 4. Kullanıcı Hikayeleri

### 4.1 Ev Kullanıcısı (VPN Senaryosu)

> "Türkiye'deki ISP'm bazı siteleri yavaşlatıyor. Cloudflare (AS13335) ve Google (AS15169) trafiğimi VPN'den geçirmek istiyorum, geri kalan trafik normal WAN'dan gitsin."

```
mergen add --asn 13335 --via wg0 --label cloudflare
mergen add --asn 15169 --via wg0 --label google
mergen apply
```

### 4.2 Çoklu WAN Kullanıcısı

> "Evde iki ISP var. İş trafiğim (Microsoft AS8075) fiber'den, torrent trafiğim LTE'den geçsin."

```
mergen add --asn 8075 --via wan_fiber --label microsoft-is
mergen add --ip 10.0.0.0/8 --via wan_lte --label torrent-peers
mergen apply
```

### 4.3 Sistem Yöneticisi (Toplu Kural)

> "Bir YAML dosyasından tüm kuralları yüklemek istiyorum."

```yaml
# /etc/mergen/rules.d/office.yaml
rules:
  - name: cloudflare
    asn: 13335
    via: wg0
    priority: 100

  - name: google-services
    asn:
      - 15169
      - 36040
    via: wg0
    priority: 200

  - name: internal
    ip:
      - 10.0.0.0/8
      - 172.16.0.0/12
    via: lan
    priority: 50
```

```
mergen import /etc/mergen/rules.d/office.yaml
mergen apply
```

### 4.4 LuCI Kullanıcısı

> "Terminal bilmiyorum. Web panelinden ASN ekleyip, hangi arayüzden gideceğini seçmek istiyorum."

LuCI'de:
1. "Mergen" sekmesine git
2. "Yeni Kural" butonuna tıkla
3. ASN veya IP gir, hedef arayüzü seç
4. "Uygula" tıkla

## 5. Mimari

### 5.1 Yüksek Seviye Mimari

```
+---------------------------------------------+
|                  LuCI UI                     |
|          (luci-app-mergen)                   |
+----------------------+----------------------+
                       |
                  UCI Config
              /etc/config/mergen
                       |
+----------------------+----------------------+
|               mergen daemon                  |
|                                              |
|  +----------+  +----------+  +------------+  |
|  | ASN      |  | Rule     |  | Route      |  |
|  | Resolver |  | Engine   |  | Manager    |  |
|  +----+-----+  +----+-----+  +-----+------+  |
|       |              |              |          |
|  +----+-----+  +----+-----+  +-----+------+  |
|  | Provider |  | nftables |  | ip rule    |  |
|  | Plugins  |  | / ipset  |  | ip route   |  |
|  +----------+  +----------+  +------------+  |
+---------------------------------------------+
```

### 5.2 Bileşenler

#### 5.2.1 ASN Resolver

Pluggable mimari ile birden fazla veri kaynağından ASN prefix listesi çözer:

| Provider         | Yöntem        | Avantaj            | Dezavantaj                |
|------------------|---------------|--------------------|---------------------------|
| RIPE RIS         | RIPE Stat API | Resmi, güncel      | Rate limit, internet şart |
| bgp.tools        | REST API      | Hızlı, kapsamlı    | Üçüncü parti bağımlılık   |
| bgpview.io       | REST API      | Kolay kullanım     | Rate limit                |
| MaxMind GeoLite2 | Yerel ASN DB  | Çevrimdışı çalışır | Periyodik güncelleme şart |
| RouteViews       | MRT/RIB dump  | En kapsamlı        | Ağır, parse gerekir       |
| IRR / RADB       | whois query   | Resmi kayıt        | Yavaş olabilir            |

**Varsayılan strateji**: Öncelik sırası ile dene, ilk başarılı sonucu kullan. Kullanıcı sıralama ve aktif provider'ları yapılandırabilir.

#### 5.2.2 Rule Engine

- Kural önceliklendirme (priority)
- Kural gruplama (label/tag)
- Çatışma tespiti (aynı prefix, farklı hedef)
- Kural birleştirme (aggregate) -- küçük CIDR'ları büyük bloklara toplama

#### 5.2.3 Route Manager

- `ip rule` ile policy routing tabloları oluşturma
- `ip route` ile rota ekleme/silme
- `nftables` set veya `ipset` ile performanslı paket eşleştirme
- IPv4 ve IPv6 destek
- Atomik uygulama: ya tüm kurallar uygulanır, ya hiçbiri (rollback)

### 5.3 Veri Akışı

```
Kullanıcı komutu / LuCI / cron tetikleyici
         |
         v
   [UCI Config güncelle]
         |
         v
   [ASN Resolver: prefix listesi çek]
         |
         v
   [Rule Engine: kuralları derle, çatışma kontrol]
         |
         v
   [Route Manager: ip rule + ip route + nftset uygula]
         |
         v
   [Durum raporla: başarılı/başarısız kurallar]
```

## 6. Teknik Gereksinimler

### 6.1 Platform

| Gereksinim     | Değer                                                |
|----------------|------------------------------------------------------|
| Hedef Platform | OpenWrt 23.05+                                       |
| Mimari Desteği | Tüm OpenWrt destekli mimariler (x86, arm, mips, ...) |
| Çalışma Ortamı | ash/busybox uyumlu shell VEYA C/Lua daemon           |
| Minimum RAM    | 32 MB (kural sayısına bağlı)                         |
| Minimum Flash  | Paket boyutu < 500 KB (LuCI hariç)                   |
| Bağımlılıklar  | ip-full, nftables (veya ipset), curl (veya wget)     |

### 6.2 Dil ve Teknoloji Seçimi

| Katman        | Teknoloji                 | Gerekçe                             |
|---------------|---------------------------|-------------------------------------|
| CLI / Daemon  | Shell (ash) + Lua         | OpenWrt-native, ek bağımlılık yok   |
| ASN Resolver  | Shell + curl/wget         | Hafif, her yerde çalışır            |
| Route Manager | Shell (ip, nft komutları) | Doğrudan kernel arayüzü             |
| UCI Binding   | Lua (libuci)              | OpenWrt standart yapılandırma       |
| LuCI App      | Lua + HTML/JS             | OpenWrt LuCI framework standardı    |
| Veri Formatı  | UCI + YAML (opsiyonel)    | UCI native, YAML import/export için |

### 6.3 UCI Yapılandırma Yapısı

```uci
# /etc/config/mergen

config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option update_interval '86400'      # 24 saat
    option default_table '100'
    option ipv6_enabled '1'

config provider 'ripe'
    option enabled '1'
    option priority '10'
    option api_url 'https://stat.ripe.net/data/announced-prefixes/data.json'

config provider 'bgptools'
    option enabled '1'
    option priority '20'
    option api_url 'https://bgp.tools/table.jsonl'

config provider 'maxmind'
    option enabled '0'
    option priority '30'
    option db_path '/usr/share/mergen/GeoLite2-ASN.mmdb'

config rule
    option name 'cloudflare'
    option asn '13335'
    option via 'wg0'
    option priority '100'
    option enabled '1'

config rule
    option name 'google'
    list asn '15169'
    list asn '36040'
    option via 'wg0'
    option priority '200'
    option enabled '1'

config rule
    option name 'office-network'
    list ip '10.0.0.0/8'
    list ip '172.16.0.0/12'
    option via 'lan'
    option priority '50'
    option enabled '1'
```

## 7. CLI Arayüzü

### 7.1 Komut Yapısı

```
mergen <komut> [seçenekler]
```

### 7.2 Komutlar

| Komut      | Açıklama                                  | Örnek                              |
|------------|-------------------------------------------|------------------------------------|
| `add`      | Yeni routing kuralı ekle                  | `mergen add --asn 13335 --via wg0` |
| `remove`   | Kural sil                                 | `mergen remove cloudflare`         |
| `list`     | Tüm kuralları listele                     | `mergen list`                      |
| `show`     | Kural detayı göster                       | `mergen show cloudflare`           |
| `apply`    | Kuralları sisteme uygula                  | `mergen apply`                     |
| `rollback` | Son uygulamayı geri al                    | `mergen rollback`                  |
| `status`   | Daemon ve kural durumu                    | `mergen status`                    |
| `update`   | ASN prefix listelerini güncelle           | `mergen update`                    |
| `resolve`  | ASN'in prefix'lerini göster (uygulamadan) | `mergen resolve 13335`             |
| `import`   | YAML/JSON dosyasından kural yükle         | `mergen import rules.yaml`         |
| `export`   | Kuralları YAML/JSON olarak dışarı aktar   | `mergen export --format yaml`      |
| `enable`   | Kural veya daemon'u etkinleştir           | `mergen enable cloudflare`         |
| `disable`  | Kural veya daemon'u devre dışı bırak      | `mergen disable cloudflare`        |
| `flush`    | Tüm Mergen route'larını temizle           | `mergen flush`                     |
| `log`      | Log kayıtlarını göster                    | `mergen log --tail 50`             |
| `diag`     | Tanı/debug bilgisi                        | `mergen diag --asn 13335`          |

### 7.3 Örnek Oturum

```bash
# ASN bazlı kural ekle
root@OpenWrt:~# mergen add --asn 13335 --via wg0 --label cloudflare
[+] Kural eklendi: cloudflare (AS13335 -> wg0)

# IP bazlı kural ekle
root@OpenWrt:~# mergen add --ip 185.70.40.0/22 --via wg0 --label protonmail
[+] Kural eklendi: protonmail (185.70.40.0/22 -> wg0)

# Kuralları listele
root@OpenWrt:~# mergen list
ID  NAME         TYPE  TARGET              VIA   PRI  STATUS
1   cloudflare   ASN   AS13335 (847 pfx)   wg0   100  pending
2   protonmail   IP    185.70.40.0/22      wg0   100  pending

# Uygula
root@OpenWrt:~# mergen apply
[*] Resolving AS13335... 847 prefixes (v4: 612, v6: 235)
[*] Creating routing table 100...
[*] Adding ip rules... done
[*] Adding nft set 'mergen_cloudflare'... 612 v4, 235 v6 entries
[*] Adding ip rules for protonmail... done
[+] 2 rules applied successfully

# Durum kontrol
root@OpenWrt:~# mergen status
Mergen v1.0.0 | OpenWrt 23.05.3
Daemon:    active (pid 1234)
Rules:     2 active, 0 pending, 0 failed
Prefixes:  849 total (613 v4, 236 v6)
Last sync: 2026-04-03 14:30:00 UTC
Next sync: 2026-04-04 14:30:00 UTC
```

## 8. LuCI Arayüzü

### 8.1 Sayfalar

| Sayfa             | İçerik                                                 |
|-------------------|--------------------------------------------------------|
| Genel Bakış       | Aktif kurallar, trafik özeti, daemon durumu            |
| Kurallar          | Kural listesi, ekle/düzenle/sil, sürükle-bırak öncelik |
| ASN Tarayıcı      | ASN ara, prefix listesini önizle, tek tıkla kural ekle |
| Arayüzler         | Mevcut WAN/VPN arayüzleri, durumlar                    |
| Provider Ayarları | ASN veri kaynakları yapılandırma                       |
| Loglar            | Canlı log akışı                                        |
| Gelişmiş          | Routing tablo ayarları, nftables/ipset tercihi, IPv6   |

### 8.2 UI Tasarımı (Wireframe)

```
+-----------------------------------------------------------+
|  Mergen - Policy Routing                  [Uygula] [Yenile]|
+-----------------------------------------------------------+
| Genel Bakis | Kurallar | ASN Tarayici | Ayarlar | Loglar  |
+-----------------------------------------------------------+
|                                                           |
|  Aktif Kurallar                                           |
|  +-----------------------------------------------------+ |
|  | [x] cloudflare   AS13335     -> wg0    847 pfx  [D][S]| |
|  | [x] google       AS15169     -> wg0    1203 pfx [D][S]| |
|  | [ ] facebook     AS32934     -> wan2   412 pfx  [D][S]| |
|  | [x] office       10.0.0.0/8  -> lan    1 pfx    [D][S]| |
|  +-----------------------------------------------------+ |
|                                       [+ Yeni Kural]      |
|                                                           |
|  Sistem Durumu                                            |
|  +--------------------------+--------------------------+  |
|  | Toplam Prefix: 2463      | Son Sync: 5 dk once      |  |
|  | Aktif Kural: 3/4         | Daemon: Calisiyor        |  |
|  +--------------------------+--------------------------+  |
+-----------------------------------------------------------+
```

## 9. Paket Yapısı

```
mergen/                         # Ana OpenWrt paketi
+-- Makefile                    # OpenWrt buildroot Makefile
+-- files/
|   +-- etc/
|   |   +-- config/
|   |   |   +-- mergen          # Varsayilan UCI config
|   |   +-- init.d/
|   |   |   +-- mergen          # Procd init script
|   |   +-- hotplug.d/
|   |   |   +-- iface/
|   |   |       +-- 50-mergen   # Interface up/down tetikleyici
|   |   +-- mergen/
|   |       +-- providers/      # ASN provider plugin'leri
|   |       |   +-- ripe.sh
|   |       |   +-- bgptools.sh
|   |       |   +-- bgpview.sh
|   |       |   +-- maxmind.sh
|   |       +-- rules.d/        # Ek kural dosyalari (YAML import)
|   +-- usr/
|       +-- bin/
|       |   +-- mergen          # Ana CLI binary/script
|       +-- lib/
|           +-- mergen/
|               +-- core.sh     # Cekirdek fonksiyonlar
|               +-- resolver.sh # ASN cozumleme
|               +-- engine.sh   # Kural motoru
|               +-- route.sh    # Route yonetimi
|               +-- utils.sh    # Yardimci fonksiyonlar
+-- luci-app-mergen/            # LuCI paketi (ayri)
    +-- Makefile
    +-- htdocs/
    |   +-- luci-static/
    |       +-- mergen/
    |           +-- mergen.css
    |           +-- mergen.js
    +-- luasrc/
        +-- controller/
        |   +-- mergen.lua
        +-- model/
        |   +-- cbi/
        |       +-- mergen.lua
        |       +-- mergen-rules.lua
        +-- view/
            +-- mergen/
                +-- overview.htm
                +-- rules.htm
                +-- status.htm
```

## 10. Güvenlik

| Risk                          | Önlem                                                     |
|-------------------------------|-----------------------------------------------------------|
| API anahtarı sızıntısı        | Anahtarlar UCI'da, dosya izinleri 0600                    |
| Komut enjeksiyonu             | Tüm kullanıcı girdileri sanitize (özellikle ASN/IP input) |
| Büyük prefix listesi DoS      | Prefix sayısı limiti (varsayılan: 10000), bellek kontrolü |
| Yetkisiz erişim               | LuCI standart auth, CLI root gerektirir                   |
| Man-in-the-middle (API)       | HTTPS zorunlu, sertifika doğrulama                        |
| Hatalı route ile erişim kaybı | Rollback mekanizması, watchdog timer                      |

## 11. Performans Gereksinimleri

| Metrik                      | Hedef                     |
|-----------------------------|---------------------------|
| Kural uygulama süresi       | < 5 sn (1000 prefix için) |
| ASN çözümleme süresi        | < 10 sn (tek ASN)         |
| Bellek kullanımı (daemon)   | < 10 MB RSS               |
| Flash kullanımı (paket)     | < 500 KB                  |
| nftset lookup performansı   | O(1) -- kernel hash table |
| Maksimum desteklenen kural  | 100+ kural                |
| Maksimum desteklenen prefix | 50.000+ prefix            |

## 12. Test Stratejisi

| Test Türü         | Kapsam                                         |
|-------------------|------------------------------------------------|
| Birim testi       | Her provider, resolver, rule engine fonksiyonu |
| Entegrasyon testi | UCI config -> route uygulama akışı             |
| E2E testi         | LuCI'den kural ekle -> trafik doğrula          |
| Performans testi  | Büyük prefix listeleri ile stres testi         |
| Platform testi    | x86 VM, Raspberry Pi (arm), GL.iNet (mips)     |
| Regresyon testi   | OpenWrt 23.05, 24.xx sürümlerinde uyumluluk    |

## 13. Fazlar ve Kilometre Taşları

### Faz 1: Çekirdek (MVP)

- [ ] ASN -> prefix çözümleme (RIPE provider)
- [ ] IP/CIDR bazlı kural ekleme
- [ ] `ip rule` + `ip route` ile routing uygulama
- [ ] Temel CLI (add, remove, list, apply, status)
- [ ] UCI yapılandırma yapısı
- [ ] Init script (procd)
- [ ] Rollback mekanizması

### Faz 2: Genişletme

- [ ] Ek ASN provider'lar (bgp.tools, bgpview, MaxMind)
- [ ] nftables set entegrasyonu (performans)
- [ ] IPv6 desteği
- [ ] YAML import/export
- [ ] Otomatik prefix güncelleme (cron)
- [ ] Hotplug entegrasyonu (interface up/down)

### Faz 3: LuCI

- [ ] luci-app-mergen paketi
- [ ] Genel bakış sayfası
- [ ] Kural yönetim sayfası
- [ ] ASN tarayıcı/önizleme
- [ ] Provider ayarları
- [ ] Log görüntüleyici

### Faz 4: Gelişmiş Özellikler

- [ ] DNS bazlı routing (dnsmasq nftset)
- [ ] Ülke bazlı toplu ASN ekleme
- [ ] Trafik istatistikleri (nftables sayaçları)
- [ ] Failover / health check
- [ ] mwan3 entegrasyonu
- [ ] OpenWrt paket deposuna gönderim

## 14. Riskler ve Azaltma

| Risk                                    | Etki   | Olasılık | Azaltma                                      |
|-----------------------------------------|--------|----------|----------------------------------------------|
| ASN API'leri rate limit / kapanış       | Yüksek | Orta     | Çoklu provider, yerel önbellek               |
| OpenWrt sürümler arası uyumsuzluk       | Orta   | Orta     | nftables + ipset fallback, sürüm kontrolü    |
| Büyük prefix listelerinde bellek taşma  | Yüksek | Düşük    | Prefix limiti, streaming işlem, ipset/nftset |
| LuCI API değişiklikleri                 | Düşük  | Düşük    | LuCI standart CBI/model kullanımı            |
| Kullanıcı hatalı route ile erişim kaybı | Yüksek | Orta     | Watchdog timer, otomatik rollback, safe mode |

## 15. Başarı Metrikleri

- OpenWrt paket deposuna kabul
- OpenWrt forumunda aktif topluluk
- En az 3 farklı ASN provider desteği
- 5 farklı donanım platformunda başarılı test
- Kullanıcı geri bildirimlerine dayalı sürekli iyileştirme

---

*Bu belge yaşayan bir dokümandır ve geliştirme sürecinde güncellenecektir.*
