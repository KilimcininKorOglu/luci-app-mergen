# Mergen - OpenWrt ASN/IP Bazlı Policy Routing

version: 1.3

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

Tek komutla ASN'in tüm prefix'lerini çözümleyip, ip rule + ip route + nftables/ipset kurallarına dönüştüren, OpenWrt-native bir policy routing aracı. Hibrit mimari: on-demand CLI komutları + hafif watchdog daemon (hotplug olayları, periyodik güncelleme, safe mode).

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
mergen add --asn 13335 --via wg0 --name cloudflare
mergen add --asn 15169 --via wg0 --name google
mergen apply
```

### 4.2 Çoklu WAN Kullanıcısı

> "Evde iki ISP var. İş trafiğim (Microsoft AS8075) fiber'den, torrent trafiğim LTE'den geçsin."

```
mergen add --asn 8075 --via wan_fiber --name microsoft-is
mergen add --ip 10.0.0.0/8 --via wan_lte --name torrent-peers
mergen apply
```

### 4.3 Sistem Yöneticisi (Toplu Kural)

> "Bir JSON dosyasından tüm kuralları yüklemek istiyorum."

```json
{
  "rules": [
    {
      "name": "cloudflare",
      "asn": 13335,
      "via": "wg0",
      "priority": 100
    },
    {
      "name": "google-services",
      "asn": [15169, 36040],
      "via": "wg0",
      "priority": 200
    },
    {
      "name": "internal",
      "ip": ["10.0.0.0/8", "172.16.0.0/12"],
      "via": "lan",
      "priority": 50
    }
  ]
}
```

```
mergen import /etc/mergen/rules.d/office.json
mergen apply
```

### 4.4 LuCI Kullanıcısı

> "Terminal bilmiyorum. Web panelinden ASN ekleyip, hangi arayüzden gideceğini seçmek istiyorum."

LuCI'de:
1. "Mergen" sekmesine git
2. "Yeni Kural" butonuna tıkla
3. ASN veya IP gir, hedef arayüzü seç
4. "Uygula" tıkla

### 4.5 Failover Senaryosu

> "VPN tünelim zaman zaman düşüyor. Düştüğünde trafik normal WAN'dan gitsin, VPN geldiğinde otomatik geri dönsün."

```
mergen add --asn 13335 --via wg0 --fallback wan --name cloudflare
mergen apply
```

### 4.6 Hata Kurtarma Senaryosu

> "Yanlış bir kural girdim ve SSH erişimim kesildi. Router'ı yeniden başlattığımda her şeyin düzelmesini istiyorum."

```bash
# Safe mode aktif — apply sonrası 60 saniye içinde onay gelmezse otomatik rollback
root@OpenWrt:~# mergen apply --safe
[*] Safe mode: 60 saniye içinde onay bekleniyor...
[*] Ping 8.8.8.8 başarısız. Otomatik rollback yapılıyor...
[+] Önceki durum geri yüklendi.
```

### 4.7 Ülke Bazlı Senaryo

> "Türkiye'deki tüm ASN'lere giden trafiği normal WAN'dan, diğer her şeyi VPN'den geçirmek istiyorum."

```
mergen add --country TR --via wan --name turkiye-direkt
mergen apply
```

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
|               mergen (CLI + Watchdog)        |
|                                              |
|  +----------+  +----------+  +------------+  |
|  | ASN      |  | Rule     |  | Route      |  |
|  | Resolver |  | Engine   |  | Manager    |  |
|  +----+-----+  +----+-----+  +-----+------+  |
|       |              |              |          |
|  +----+-----+  +----+-----+  +-----+------+  |
|  | Provider |  | nftables |  | ip rule    |  |
|  | Plugins  |  | / ipset  |  | ip route   |  |
|  +----+-----+  +----------+  +------------+  |
|       |                                       |
|  +----+-----+                                 |
|  | Cache    |                                 |
|  | Layer    |                                 |
|  +----------+                                 |
+---------------------------------------------+
```

### 5.1.1 Hibrit Daemon Modeli

Mergen iki bileşenden oluşur:

**`mergen` (CLI)**: On-demand çalışır, kullanıcı komutlarını işler. Komut tamamlanınca süreç sonlanır. Tüm ağır işlemler (ASN çözümleme, route uygulama, import/export) burada yapılır.

**`mergen-watchdog` (Daemon)**: Procd tarafından yönetilen hafif daemon. Görevleri:
- Hotplug olaylarını dinleme (arayüz up/down)
- Periyodik prefix güncelleme (cron yerine dahili zamanlayıcı)
- Safe mode ping kontrolü (apply sonrası bağlantı doğrulama)
- Arayüz sağlık kontrolü (failover tetikleyici)

İki bileşen arasındaki iletişim:
- **UCI config**: Ortak yapılandırma kaynağı
- **Lock dosyası**: `/var/lock/mergen.lock` -- eşzamanlı erişim kontrolü
- **Durum dosyası**: `/tmp/mergen/status.json` -- watchdog'un güncel durumu

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
| Veri Formatı  | UCI + JSON                | UCI native, JSON import/export için |
| Watchdog      | Shell (ash) + procd       | Hibrit model, hafif daemon          |

### 6.3 UCI Yapılandırma Yapısı

```uci
# /etc/config/mergen

config mergen 'global'
    option enabled '1'
    option log_level 'info'
    option update_interval '86400'      # 24 saat
    option default_table '100'
    option ipv6_enabled '1'
    option cache_dir '/tmp/mergen/cache'
    option watchdog_enabled '1'
    option watchdog_interval '60'
    option safe_mode_ping_target '8.8.8.8'
    option config_version '1'

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
| `import`   | JSON dosyasından kural yükle              | `mergen import rules.json`         |
| `export`   | Kuralları UCI veya JSON olarak dışarı aktar | `mergen export --format json`      |
| `enable`   | Kural veya daemon'u etkinleştir           | `mergen enable cloudflare`         |
| `disable`  | Kural veya daemon'u devre dışı bırak      | `mergen disable cloudflare`        |
| `flush`    | Tüm Mergen route'larını temizle           | `mergen flush`                     |
| `log`      | Log kayıtlarını göster                    | `mergen log --tail 50`             |
| `diag`     | Tanı/debug bilgisi                        | `mergen diag --asn 13335`          |
| `version`  | Sürüm bilgisi göster                      | `mergen version`                   |
| `help`     | Komut yardımı                             | `mergen help add`                  |
| `validate` | Config doğrulama (apply etmeden)          | `mergen validate`                  |

### 7.3 Örnek Oturum

```bash
# ASN bazlı kural ekle
root@OpenWrt:~# mergen add --asn 13335 --via wg0 --name cloudflare
[+] Kural eklendi: cloudflare (AS13335 -> wg0)

# IP bazlı kural ekle
root@OpenWrt:~# mergen add --ip 185.70.40.0/22 --via wg0 --name protonmail
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

### 7.4 Hata Mesajları

Mergen, kullanıcıya açıklayıcı hata mesajları verir:

```bash
# Geçersiz ASN
root@OpenWrt:~# mergen add --asn abc --via wg0 --name test
[!] Hata: 'abc' geçerli bir ASN numarası değil. Örnek: 13335

# Olmayan arayüz
root@OpenWrt:~# mergen add --asn 13335 --via wg99 --name cf
[!] Hata: 'wg99' arayüzü bulunamadı. Mevcut arayüzler: wan, wg0, lan

# Prefix limiti aşımı
root@OpenWrt:~# mergen apply
[!] Uyarı: cloudflare (AS13335) prefix limiti (10000) aşıyor (12453 prefix).
    --force ile zorlayabilir veya limiti artırabilirsiniz.

# API hatası ve provider fallback
root@OpenWrt:~# mergen resolve 13335
[!] RIPE API yanıt vermedi (timeout: 30s). Sonraki provider deneniyor...
[*] bgp.tools: 847 prefix bulundu (v4: 612, v6: 235)

# Apply hatası ve otomatik rollback
root@OpenWrt:~# mergen apply --safe
[*] Kurallar uygulanıyor...
[*] Safe mode: bağlantı testi yapılıyor (8.8.8.8)...
[!] Bağlantı testi başarısız. Otomatik rollback yapılıyor...
[+] Önceki durum geri yüklendi. Kurallarınızı kontrol edin.
```

## 8. LuCI Arayüzü

LuCI1 (Lua/CBI) mimarisi bilinçli olarak tercih edilmiştir. LuCI1, OpenWrt 23.05 ve sonraki sürümlerde hâlâ tam desteklenmekte olup daha geniş cihaz uyumluluğu ve daha düşük kaynak tüketimi sağlar. Server-side rendering modeli, düşük bellekli cihazlarda (32 MB RAM) daha verimli çalışır.

### 8.1 Genel Bakış Sayfası

Ana sayfa. Kullanıcı Mergen sekmesini açtığında ilk karşılaştığı ekran. Tüm sistemin anlık durumunu özetler.

**Üst Bant (Durum Kartları)**:

| Kart              | Gösterge                                                        |
|-------------------|-----------------------------------------------------------------|
| Daemon Durumu     | Çalışıyor / Durdu / Hata — yeşil/kırmızı/sarı renk göstergesi |
| Toplam Kural      | Aktif / Pasif / Hatalı kural sayıları                           |
| Toplam Prefix     | IPv4 ve IPv6 prefix sayıları ayrı ayrı                         |
| Son Senkronizasyon| Tarih/saat + "X dakika önce" formatında                         |
| Sonraki Sync      | Bir sonraki otomatik güncelleme zamanı                          |

**Aktif Kurallar Tablosu**:
- Tüm kuralların özet listesi (ad, tür, hedef, arayüz, prefix sayısı, durum)
- Durum sütununda renkli badge: aktif (yeşil), pasif (gri), hata (kırmızı), beklemede (sarı)
- Satır tıklanınca ilgili kuralın detay sayfasına yönlendirme

**Hızlı Eylemler**:
- [Tümünü Uygula] — beklemedeki tüm kuralları uygula
- [Prefix Güncelle] — tüm ASN prefix listelerini şimdi güncelle
- [Daemon Yeniden Başlat] — mergen servisini restart et

**Son İşlemler Akışı**:
- Son 10 işlem logu (kural ekleme, silme, uygulama, güncelleme)
- Her satırda: zaman damgası, işlem türü, sonuç (başarılı/başarısız)
- "Tüm logları gör" bağlantısı ile Loglar sayfasına yönlendirme

### 8.2 Kurallar Sayfası

Kural yönetiminin merkezi. Tüm CRUD işlemleri bu sayfadan yapılır.

**Kural Listesi Tablosu**:

| Sütun       | Açıklama                                                       |
|-------------|----------------------------------------------------------------|
| Sıra        | Sürükle-bırak ile öncelik değiştirme tutamacı                 |
| Durum       | Açma/kapama toggle switch                                      |
| Ad          | Kuralın adı (tıklanabilir, düzenleme formunu açar)             |
| Tür         | ASN / IP / Karma — ikon ile gösterim                           |
| Hedef       | ASN numaraları veya IP/CIDR blokları (kısaltılmış, hover'da tam liste) |
| Arayüz      | Hedef arayüz adı (wg0, wan2, vb.) — dropdown ile değiştirilebilir |
| Prefix      | Çözümlenmiş prefix sayısı (IPv4 + IPv6 ayrı)                  |
| Öncelik     | Sayısal değer (düzenlenebilir)                                 |
| İşlemler    | [Düzenle] [Kopyala] [Sil] butonları                           |

**Yeni Kural Ekleme Formu** (sayfa içi açılır panel):

- **Kural Adı**: Serbest metin, benzersiz olmalı (validasyon)
- **Kural Türü**: Radio buton — ASN / IP / Karma
- **ASN Girişi** (tür=ASN seçildiğinde):
  - Tek ASN numarası girişi veya virgülle ayrılmış çoklu ASN
  - "ASN Ara" butonu ile ASN Tarayıcı sayfasına geçiş
  - Girilen ASN'in geçerliliği anlık kontrol (API sorgusu)
- **IP Girişi** (tür=IP seçildiğinde):
  - IP/CIDR formatında giriş (satır başına bir adet)
  - CIDR validasyonu (geçersiz formatta uyarı)
- **Hedef Arayüz**: Dropdown — sistemdeki mevcut arayüzler (wg0, wan, wan2, vb.)
- **Öncelik**: Sayısal giriş (varsayılan: 100, aralık: 1-32000)
- **Açıklama**: Opsiyonel serbest metin alanı
- [Kaydet] ve [İptal] butonları

**Toplu İşlemler**:
- Çoklu seçim checkbox'ları ile toplu aktif/pasif yapma
- Toplu silme (onay dialogu ile)
- Toplu arayüz değiştirme
- JSON olarak dışa aktarma (seçili kurallar)

**Sürükle-Bırak Önceliklendirme**:
- Kural satırlarını sürükleyerek sıralama değiştirme
- Sıralama değişince öncelik değerleri otomatik yeniden hesaplanır
- Değişiklikler "Uygula" butonuna basılana kadar kaydedilmez

### 8.3 ASN Tarayıcı Sayfası

ASN keşif ve önizleme aracı. Kullanıcı kural eklemeden önce ASN'leri araştırabilir.

**Arama Bölümü**:
- **ASN Numarası ile Arama**: "AS13335" veya "13335" formatında giriş
- **Organizasyon Adı ile Arama**: "Cloudflare", "Google" gibi metin arama (RIPE ve bgpview provider'ları destekler)
- **IP Adresi ile Ters Arama**: Bir IP adresinin hangi ASN'e ait olduğunu bulma
- Arama sonuçları anlık olarak (debounced) listelenir

**ASN Detay Paneli** (bir ASN seçildiğinde):

| Bilgi              | Açıklama                                           |
|--------------------|-----------------------------------------------------|
| ASN Numarası       | AS13335                                             |
| Organizasyon       | Cloudflare, Inc.                                    |
| Ülke               | US (bayrak ikonu ile)                                |
| RIR                | ARIN / RIPE / APNIC vb.                            |
| IPv4 Prefix Sayısı | Toplam sayı ve liste                                |
| IPv6 Prefix Sayısı | Toplam sayı ve liste                                |
| Toplam IP Sayısı   | IPv4 adres havuzu büyüklüğü                        |
| Kaynak Provider    | Bilginin hangi provider'dan geldiği                  |

**Prefix Listesi Önizleme**:
- ASN'e ait tüm prefix'lerin sayfalanmış tablosu
- Sütunlar: Prefix, Versiyon (v4/v6), Adres Sayısı
- Filtreleme: Sadece IPv4 / Sadece IPv6 / Tümü
- Sıralama: Prefix büyüklüğüne veya adres sırasına göre

**Hızlı Kural Oluşturma**:
- [Bu ASN için Kural Ekle] butonu
- Tıklandığında hedef arayüz seçme dropdown'u açılır
- Arayüz seçilince doğrudan Kurallar sayfasına yönlendirir (kural eklenmiş olarak)

**Karşılaştırma Modu**:
- Birden fazla ASN seçip yan yana karşılaştırma
- Ortak prefix'leri vurgulama (örtüşen CIDR blokları)

### 8.4 Arayüzler Sayfası

Sistemdeki ağ arayüzlerinin durumu ve Mergen ile ilişkisi.

**Arayüz Listesi**:

| Sütun             | Açıklama                                                 |
|-------------------|----------------------------------------------------------|
| Arayüz Adı       | wan, wan2, wg0, tun0 vb.                                |
| Tür               | WAN / VPN (WireGuard) / VPN (OpenVPN) / LAN             |
| Durum             | Aktif (yeşil) / Pasif (kırmızı) / Bağlanıyor (sarı)     |
| IP Adresi         | Arayüze atanmış IP                                       |
| Gateway           | Varsayılan ağ geçidi                                     |
| Mergen Kuralları  | Bu arayüze yönlendirilmiş kural sayısı                   |
| Toplam Prefix     | Bu arayüze yönlendirilmiş toplam prefix sayısı           |
| Trafik            | Anlık giriş/çıkış bant genişliği (varsa)                 |

**Arayüz Detay Paneli** (bir arayüz seçildiğinde):
- Arayüze atanmış tüm Mergen kurallarının listesi
- Routing tablosu detayı (`ip route show table X` çıktısı)
- nftables set içeriği (bu arayüze ait set'teki prefix sayısı)
- Bağlantı testi: [Ping Gateway] [Traceroute] butonları
- Son 24 saatlik arayüz up/down geçmişi

**Sağlık Kontrolü**:
- Her arayüz için periyodik ping testi sonuçları
- Gecikme (latency) ve paket kaybı metrikleri
- Arayüz düştüğünde hangi kuralların etkileneceğinin gösterimi

### 8.5 Provider Ayarları Sayfası

ASN veri kaynağı provider'larının yapılandırması.

**Provider Listesi**:

| Sütun         | Açıklama                                                  |
|---------------|-----------------------------------------------------------|
| Öncelik       | Sürükle-bırak ile sıralama (düşük numara = yüksek öncelik)|
| Provider Adı  | RIPE RIS, bgp.tools, bgpview.io, MaxMind, RouteViews, IRR|
| Durum         | Aktif / Pasif toggle switch                               |
| Son Sorgu     | Son başarılı sorgu zamanı                                 |
| Başarı Oranı  | Son 24 saatteki başarılı/başarısız sorgu oranı            |
| Ort. Yanıt    | Ortalama yanıt süresi (ms)                                |

**Provider Detay/Düzenleme Formu** (her provider için):

- **RIPE RIS**:
  - API URL (varsayılan dolu, değiştirilebilir)
  - Zaman aşımı süresi (saniye)
  - Rate limit ayarı (saniyede maks sorgu)

- **bgp.tools**:
  - API URL
  - API anahtarı (opsiyonel, premium erişim için)
  - Zaman aşımı süresi

- **bgpview.io**:
  - API URL
  - Zaman aşımı süresi
  - Rate limit ayarı

- **MaxMind GeoLite2**:
  - Veritabanı dosya yolu (`/usr/share/mergen/GeoLite2-ASN.mmdb`)
  - Lisans anahtarı (otomatik güncelleme için)
  - Otomatik güncelleme açık/kapalı
  - Son veritabanı güncelleme tarihi

- **RouteViews**:
  - MRT dump URL
  - İndirme zamanlaması (büyük dosya, gece saatleri önerisi)

- **IRR / RADB**:
  - Whois sunucu adresi
  - Zaman aşımı süresi

**Genel Provider Ayarları**:
- Önbellek süresi (varsayılan: 24 saat)
- Fallback stratejisi: Sıralı deneme / Paralel sorgu / Sadece önbellek
- Önbellek temizleme butonu: [Tüm Önbelleği Temizle]
- Provider test butonu: [Tümünü Test Et] — her provider'a test sorgusu gönderir

### 8.6 Loglar Sayfası

Mergen daemon'unun log kayıtlarını gerçek zamanlı görüntüleme ve filtreleme.

**Canlı Log Akışı**:
- Otomatik kaydırma ile gerçek zamanlı log görüntüleme (XHR polling (luci-mod-rpc))
- Duraklatma/devam ettirme butonu
- Her log satırında: zaman damgası, seviye, bileşen, mesaj

**Filtreleme Araçları**:

| Filtre          | Seçenekler                                            |
|-----------------|-------------------------------------------------------|
| Log Seviyesi    | DEBUG / INFO / WARNING / ERROR (çoklu seçim)          |
| Bileşen         | Resolver / Engine / Route / Provider / Daemon / LuCI  |
| Kural Adı       | Belirli bir kurala ait logları filtrele                |
| Zaman Aralığı   | Son 1 saat / 6 saat / 24 saat / 7 gün / Özel aralık |
| Metin Arama     | Serbest metin arama (regex destekli)                  |

**Log Detay Görünümü**:
- Bir log satırına tıklandığında genişleyen detay paneli
- İlişkili bağlam bilgisi (hangi kural, hangi provider, hangi prefix)
- Hata loglarında stack trace veya komut çıktısı

**Dışa Aktarma**:
- Filtrelenmiş logları düz metin (.log) olarak indirme
- Hata raporlama için "Tanı Paketi Oluştur" butonu (son loglar + yapılandırma + sistem bilgisi)

### 8.7 Gelişmiş Ayarlar Sayfası

İleri düzey kullanıcılar için sistem yapılandırması.

**Routing Tablosu Ayarları**:
- Varsayılan routing tablo numarası (varsayılan: 100)
- Tablo numarası aralığı (min-max)
- `ip rule` öncelik başlangıç değeri

**Paket Eşleştirme Motoru**:
- nftables set (önerilen, OpenWrt 23.05+)
- ipset (eski sürümler için fallback)
- Seçim yapıldığında uyumluluk kontrolü ve uyarı mesajı

**IPv6 Yapılandırması**:
- IPv6 desteği açık/kapalı toggle
- IPv6 prefix'leri ayrı tablo mu, aynı tablo mu?
- IPv6-only kurallar için özel ayarlar

**Performans Ayarları**:

| Ayar                     | Açıklama                              | Varsayılan |
|--------------------------|---------------------------------------|------------|
| Maks Prefix Limiti       | Tek kural başına maks prefix sayısı   | 10000      |
| Toplam Prefix Limiti     | Tüm kurallar için toplam maks prefix  | 50000      |
| Güncelleme Aralığı       | Otomatik prefix güncelleme periyodu   | 24 saat    |
| API Zaman Aşımı          | Provider API sorgu timeout'u          | 30 sn      |
| Paralel Sorgu Sayısı     | Eşzamanlı provider sorgu limiti       | 2          |

**Güvenlik Ayarları**:
- Rollback watchdog süresi (varsayılan: 60 saniye)
- Safe mode: Uygulama sonrası bağlantı testi, başarısızsa otomatik geri al
- Ping hedefi (safe mode kontrolü için, varsayılan: 8.8.8.8)

**Bakım İşlemleri**:
- [Tüm Route'ları Temizle (Flush)] — Mergen tarafından oluşturulan tüm kuralları sil
- [Fabrika Ayarlarına Dön] — UCI config'i varsayılana sıfırla
- [Yapılandırmayı Yedekle] — Mevcut UCI config'i dosya olarak indir
- [Yapılandırmayı Geri Yükle] — Yedek dosyasından geri yükle
- Mergen sürüm bilgisi ve güncelleme kontrolü

### 8.8 UI Tasarımı (Wireframe)

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
+-- tests/                      # Test dosyalari
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
|   |       +-- rules.d/        # Ek kural dosyalari (JSON import)
|   +-- usr/
|       +-- bin/
|       |   +-- mergen          # Ana CLI binary/script
|       +-- sbin/
|       |   +-- mergen-watchdog # Watchdog daemon scripti
|       +-- lib/
|           +-- mergen/
|               +-- core.sh     # Cekirdek fonksiyonlar
|               +-- resolver.sh # ASN cozumleme
|               +-- engine.sh   # Kural motoru
|               +-- route.sh    # Route yonetimi
|               +-- utils.sh    # Yardimci fonksiyonlar
+-- luci-app-mergen/            # LuCI paketi (ayri)
    +-- Makefile
    +-- po/                     # i18n: Ingilizce birincil, Turkce ikincil
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

## 10.1 Yapılandırma Migrasyon Stratejisi

UCI config yapısı sürümler arasında değişebilir. Güvenli geçiş mekanizması:

| Mekanizma                    | Açıklama                                                       |
|------------------------------|----------------------------------------------------------------|
| Config versiyonlama          | `option config_version '1'` — mevcut config şema sürümü       |
| Otomatik migrasyon           | `/usr/lib/mergen/migrate.sh` — sürüm yükseltmede çalışır      |
| Geriye dönük uyumluluk       | 1 önceki major sürümün config formatı desteklenir              |
| Yedekleme                    | Migrasyon öncesi otomatik yedek: `/tmp/mergen/config.backup`   |

Migrasyon akışı:
1. Paket güncellemesi sırasında `postinst` scripti `migrate.sh`'ı çağırır
2. `config_version` kontrol edilir
3. Eski sürümdeyse dönüşüm uygulanır, yeni `config_version` yazılır
4. Başarısızlıkta yedekten geri yükleme

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

**Test Altyapısı**:

| Bileşen         | Teknoloji                                                |
|-----------------|----------------------------------------------------------|
| Shell testleri  | shunit2 (ash/busybox uyumlu)                             |
| Lua testleri    | busted (LuCI bileşenleri için)                           |
| CI ortamı       | GitHub Actions + OpenWrt SDK Docker imajı                |
| Lokal test      | OpenWrt x86 QEMU VM                                      |
| Donanım testi   | x86 VM, Raspberry Pi (arm), GL.iNet (mips) — release öncesi |

**Test Dağılımı (Fazlara Göre)**:
- Faz 1: Birim testleri (resolver, rule engine, route manager)
- Faz 2: Entegrasyon testleri (rollback, nftables, loglama)
- Faz 3: Provider testleri (6 provider, fallback, cache)
- Faz 4-5: LuCI testleri (E2E, tarayıcı uyumluluk)
- Faz 6: Performans stres testi, platform doğrulama, regresyon

## 13. Fazlar ve Kilometre Taşları

### Faz 1: Temel Altyapı ve MVP CLI

İlk çalışan `mergen add --asn 13335 --via wg0 && mergen apply` akışını sağlayan minimum altyapı.

**Proje İskeleti** *(Bölüm 9)*:
- [ ] OpenWrt buildroot Makefile yapısı
- [ ] Paket dizin hiyerarşisi (`files/etc/`, `files/usr/bin/`, `files/usr/lib/mergen/`)
- [ ] Varsayılan UCI config dosyası (`/etc/config/mergen`)
- [ ] Procd init script (`/etc/init.d/mergen`)

**UCI Yapılandırma** *(Bölüm 6.3)*:
- [ ] `config mergen 'global'` blok yapısı (enabled, log_level, default_table)
- [ ] `config provider` blok yapısı (enabled, priority, api_url)
- [ ] `config rule` blok yapısı (name, asn/ip, via, priority, enabled)
- [ ] UCI okuma/yazma fonksiyonları (`core.sh` — libuci veya `uci` CLI wrapper)

**ASN Resolver — RIPE Provider** *(Bölüm 5.2.1)*:
- [ ] Provider plugin altyapısı (`/etc/mergen/providers/` dizini, plugin arayüzü)
- [ ] RIPE Stat API entegrasyonu (`ripe.sh` — announced-prefixes endpoint)
- [ ] API yanıt parse (JSON parse — jsonfilter veya Lua cjson)
- [ ] Prefix listesini dosyaya kaydetme (önbellek temel yapısı)
- [ ] Girdi validasyonu: ASN numarası format kontrolü *(Bölüm 10)*

**Rule Engine — Temel** *(Bölüm 5.2.2)*:
- [ ] Kural ekleme/silme (UCI'ye yazma)
- [ ] Kural listeleme (UCI'den okuma, formatlı çıktı)
- [ ] Kural etkinleştirme/devre dışı bırakma

**Route Manager — Temel** *(Bölüm 5.2.3)*:
- [ ] `ip rule` ile policy routing tablosu oluşturma
- [ ] `ip route` ile prefix başına rota ekleme/silme
- [ ] Routing tablo numarası yönetimi (varsayılan: 100)
- [ ] Girdi validasyonu: IP/CIDR format kontrolü *(Bölüm 10)*

**CLI Komutları — Temel** *(Bölüm 7.2)*:
- [ ] `mergen add` — ASN veya IP/CIDR kuralı ekleme (`--asn`, `--ip`, `--via`, `--name`, `--priority`)
- [ ] `mergen remove` — İsme göre kural silme
- [ ] `mergen list` — Tüm kuralları tablo formatında listeleme
- [ ] `mergen apply` — Bekleyen kuralları sisteme uygulama
- [ ] `mergen status` — Daemon durumu, kural sayıları, son sync zamanı
- [ ] `mergen version` — Sürüm bilgisi gösterme
- [ ] `mergen help` — Komut yardımı (`mergen help add`)
- [ ] `mergen validate` — Config doğrulama (apply etmeden)

**Watchdog Temel Altyapısı** *(Bölüm 5.1.1)*:
- [ ] `mergen-watchdog` daemon scripti (`/usr/sbin/mergen-watchdog`)
- [ ] Procd service tanımı (init.d entegrasyonu)
- [ ] Lock dosyası mekanizması (CLI ↔ watchdog koordinasyonu)

**Birim Testleri — Temel** *(Bölüm 12)*:
- [ ] shunit2 test altyapısı kurulumu
- [ ] Resolver birim testleri (RIPE provider parse, hata durumları)
- [ ] Rule engine birim testleri (ekleme, silme, listeleme)
- [ ] Route manager birim testleri (ip rule/route komut üretimi)

**Kilometre Taşı**: `mergen add --asn 13335 --via wg0 && mergen apply` komutu çalışır, trafik wg0 üzerinden yönlendirilir. `mergen version` ve `mergen help` çalışır. Temel birim testleri geçer.

---

### Faz 2: Güvenilirlik ve Güvenlik

Uzaktan erişilen cihazda güvenle çalışabilecek seviyeye getirme. Atomik uygulama, geri alma, performanslı paket eşleştirme.

**Rollback Mekanizması** *(Bölüm 5.2.3, 10)*:
- [ ] Uygulama öncesi mevcut routing durumunu kaydetme (snapshot)
- [ ] `mergen rollback` — son uygulama öncesine geri dönme
- [ ] Atomik uygulama: tüm kurallar başarılıysa tamamla, herhangi biri başarısızsa geri al
- [ ] Watchdog timer: uygulama sonrası X saniye içinde onay gelmezse otomatik rollback *(Bölüm 8.7)*
- [ ] Safe mode: uygulama sonrası bağlantı testi (ping hedefi), başarısızsa geri al *(Bölüm 8.7)*

**nftables Set Entegrasyonu** *(Bölüm 5.2.3, 11)*:
- [ ] nftables set oluşturma (`nft add set` — her kural için ayrı set)
- [ ] Prefix'leri set'e toplu ekleme (`nft add element`)
- [ ] ip rule ile nftables set eşleştirme (fwmark tabanlı)
- [ ] ipset fallback (OpenWrt 22.03 ve öncesi için)
- [ ] Paket eşleştirme motoru seçimi (nftables vs ipset — otomatik algılama)
- [ ] Performans doğrulama: 1000 prefix < 5 sn *(Bölüm 11)*

**Loglama Altyapısı** *(Bölüm 8.6)*:
- [ ] Log seviyeleri: DEBUG, INFO, WARNING, ERROR
- [ ] Bileşen etiketleme: Resolver, Engine, Route, Provider, Daemon
- [ ] Syslog entegrasyonu (logread uyumlu)
- [ ] `mergen log` komutu — `--tail`, `--level` filtreleri *(Bölüm 7.2)*

**Ek CLI Komutları** *(Bölüm 7.2)*:
- [ ] `mergen show` — tekil kural detayı (prefix listesi dahil)
- [ ] `mergen enable` / `mergen disable` — kural toggle
- [ ] `mergen flush` — tüm Mergen route'larını temizle
- [ ] `mergen diag` — tanı bilgisi (routing tabloları, nft set'ler, arayüz durumları)

**Güvenlik Sertleştirme** *(Bölüm 10)*:
- [ ] Tüm kullanıcı girdilerinde shell injection koruması (ASN, IP, interface adı)
- [ ] Prefix sayısı limiti (varsayılan: 10000/kural, 50000/toplam) *(Bölüm 8.7, 11)*
- [ ] HTTPS zorunluluğu (provider API çağrıları)
- [ ] UCI dosya izinleri (0600)

**Entegrasyon Testleri — Faz 2** *(Bölüm 12)*:
- [ ] Rollback entegrasyon testleri (snapshot → hata → geri alma akışı)
- [ ] nftables/ipset entegrasyon testleri (set oluşturma, element ekleme)
- [ ] Loglama entegrasyon testleri (syslog çıktı doğrulama)

**Kilometre Taşı**: Hatalı kural uygulandığında cihaz erişimi kesilmez, otomatik geri alma çalışır.

---

### Faz 3: Çoklu Provider ve Gelişmiş Özellikler

Tüm 6 ASN veri kaynağı, IPv6, otomatik güncelleme, import/export.

**Ek ASN Provider'lar** *(Bölüm 5.2.1, 8.5)*:
- [ ] bgp.tools provider (`bgptools.sh` — REST API, opsiyonel API key)
- [ ] bgpview.io provider (`bgpview.sh` — REST API)
- [ ] MaxMind GeoLite2 provider (`maxmind.sh` — yerel MMDB okuma, çevrimdışı)
- [ ] RouteViews provider (MRT/RIB dump indirme ve parse)
- [ ] IRR / RADB provider (whois sorgusu)
- [ ] Her provider için: zaman aşımı, rate limit, hata yönetimi ayarları *(Bölüm 8.5)*

**Provider Yönetimi** *(Bölüm 5.2.1, 8.5)*:
- [ ] Öncelik sırasına göre fallback (ilk başarılı sonucu kullan)
- [ ] Provider sağlık izleme (başarı oranı, ortalama yanıt süresi)
- [ ] Önbellek yönetimi (TTL bazlı, varsayılan: 24 saat)
- [ ] `config provider` UCI yapılandırması (per-provider ayarlar)

**IPv6 Desteği** *(Bölüm 5.2.3, 8.7)*:
- [ ] IPv6 prefix çözümleme (provider'lardan v6 prefix çekme)
- [ ] `ip -6 rule` + `ip -6 route` ile IPv6 routing
- [ ] nftables IPv6 set desteği (inet family)
- [ ] Dual-stack: aynı kural için v4+v6 prefix'leri birlikte yönetme
- [ ] IPv6 açma/kapama ayarı (`option ipv6_enabled`)

**Gelişmiş Rule Engine** *(Bölüm 5.2.2)*:
- [ ] Çatışma tespiti: aynı prefix farklı hedeflere yönlendiriliyorsa uyarı
- [ ] Kural birleştirme (aggregate): küçük CIDR'ları büyük bloklara toplama
- [ ] Kural gruplama: label/tag sistemi

**JSON Import/Export** *(Bölüm 4.3, 7.2)*:
- [ ] `mergen import` -- JSON dosyasından kural yükleme
- [ ] `mergen export` -- mevcut kuralları JSON olarak dışa aktarma
- [ ] `/etc/mergen/rules.d/` dizininden otomatik yükleme

**Otomatik Güncelleme** *(Bölüm 3.1)*:
- [ ] Cron entegrasyonu: periyodik prefix güncelleme (`option update_interval`)
- [ ] `mergen update` komutu — manuel güncelleme tetikleme
- [ ] Güncelleme sonrası otomatik apply (opsiyonel)

**Hotplug Entegrasyonu** *(Bölüm 9)*:
- [ ] `/etc/hotplug.d/iface/50-mergen` — interface up/down olaylarında kural yeniden uygulama
- [ ] VPN tüneli düştüğünde ilgili kuralları pasife çekme
- [ ] VPN tüneli geldiğinde ilgili kuralları yeniden aktive etme

**Ek CLI** *(Bölüm 7.2)*:
- [ ] `mergen resolve` — ASN prefix'lerini göster (uygulamadan)

**Provider Testleri — Faz 3** *(Bölüm 12)*:
- [ ] Her 6 provider için birim testleri (API parse, hata durumları, timeout)
- [ ] Fallback/cache entegrasyon testleri
- [ ] IPv6 prefix çözümleme testleri

**Kilometre Taşı**: 6 provider çalışır, IPv6 desteklenir, prefix'ler otomatik güncellenir, interface değişikliklerinde kurallar dinamik uyarlanır.

---

### Faz 4: LuCI — Temel Sayfalar

Web panelinden çalışan temel kural yönetimi. Dört çekirdek sayfa.

**Paket Altyapısı** *(Bölüm 9)*:
- [ ] luci-app-mergen paket yapısı (Makefile, controller, model, view)
- [ ] LuCI menü entegrasyonu (Services -> Mergen)
- [ ] CSS/JS statik dosyalar (`htdocs/luci-static/mergen/`)
- [ ] RPC backend (ubus veya luci-mod-rpc üzerinden mergen komutlarına erişim)

**8.1 Genel Bakış Sayfası** *(Bölüm 8.1)*:
- [ ] Durum kartları: daemon durumu, toplam kural, toplam prefix, son/sonraki sync
- [ ] Aktif kurallar özet tablosu (ad, tür, hedef, arayüz, prefix sayısı, durum badge)
- [ ] Hızlı eylemler: [Tümünü Uygula], [Prefix Güncelle], [Daemon Yeniden Başlat]
- [ ] Son 10 işlem akışı (zaman damgası, işlem türü, sonuç)

**8.2 Kurallar Sayfası — Temel** *(Bölüm 8.2)*:
- [ ] Kural listesi tablosu (durum toggle, ad, tür, hedef, arayüz, prefix, öncelik)
- [ ] Yeni kural ekleme formu (ASN/IP seçimi, arayüz dropdown, öncelik, ad)
- [ ] Kural düzenleme (inline veya modal form)
- [ ] Kural silme (onay dialogu)
- [ ] ASN/IP girdi validasyonu (format kontrolü, geçerlilik sorgusu)

**8.5 Provider Ayarları — Temel** *(Bölüm 8.5)*:
- [ ] Provider listesi (ad, durum toggle, öncelik, son sorgu zamanı)
- [ ] Provider aktif/pasif toggle
- [ ] Per-provider ayar formları (API URL, timeout, rate limit)
- [ ] MaxMind: veritabanı yolu, lisans anahtarı, güncelleme durumu

**8.7 Gelişmiş Ayarlar — Temel** *(Bölüm 8.7)*:
- [ ] Routing tablo numarası ayarı
- [ ] Paket eşleştirme motoru seçimi (nftables/ipset)
- [ ] IPv6 toggle
- [ ] Prefix limiti ayarları
- [ ] Güncelleme aralığı ayarı

**LuCI Testleri — Faz 4** *(Bölüm 12)*:
- [ ] busted ile LuCI controller/model birim testleri
- [ ] RPC backend entegrasyon testleri

**Kilometre Taşı**: Kullanıcı LuCI'den kural ekleyip uygulayabilir, provider ayarlarını değiştirebilir.

---

### Faz 5: LuCI — Gelişmiş Sayfalar

Tüm 7 sayfanın tam özellikli hali. İleri düzey etkileşimler.

**8.2 Kurallar Sayfası — Gelişmiş** *(Bölüm 8.2)*:
- [ ] Sürükle-bırak ile kural önceliklendirme
- [ ] Toplu işlemler: çoklu seçim, toplu aktif/pasif, toplu silme, toplu arayüz değiştirme
- [ ] Kural kopyalama
- [ ] JSON olarak seçili kuralları dışa aktarma

**8.3 ASN Tarayıcı Sayfası** *(Bölüm 8.3)*:
- [ ] ASN numarası ile arama
- [ ] Organizasyon adı ile arama
- [ ] IP adresi ile ters ASN arama
- [ ] ASN detay paneli (organizasyon, ülke, RIR, prefix sayıları, kaynak provider)
- [ ] Prefix listesi önizleme (sayfalanmış tablo, v4/v6 filtre, sıralama)
- [ ] [Bu ASN için Kural Ekle] — tek tıkla kural oluşturma
- [ ] Karşılaştırma modu: birden fazla ASN yan yana, ortak prefix vurgulama

**8.4 Arayüzler Sayfası** *(Bölüm 8.4)*:
- [ ] Arayüz listesi (ad, tür, durum, IP, gateway, Mergen kural/prefix sayısı, trafik)
- [ ] Arayüz detay paneli (atanmış kurallar, routing tablosu, nft set içeriği)
- [ ] Bağlantı testi: [Ping Gateway], [Traceroute]
- [ ] Sağlık kontrolü: ping sonuçları, gecikme/paket kaybı metrikleri
- [ ] Arayüz up/down geçmişi (son 24 saat)

**8.6 Loglar Sayfası** *(Bölüm 8.6)*:
- [ ] Canlı log akışı (otomatik kaydırma, duraklatma/devam)
- [ ] Filtreleme: log seviyesi, bileşen, kural adı, zaman aralığı, regex metin arama
- [ ] Log satırı detay paneli (bağlam bilgisi, ilişkili kural/provider/prefix)
- [ ] Dışa aktarma: filtrelenmiş logları .log olarak indirme
- [ ] Tanı Paketi Oluştur (loglar + config + sistem bilgisi)

**8.7 Gelişmiş Ayarlar — Tam** *(Bölüm 8.7)*:
- [ ] Rollback watchdog süresi ayarı
- [ ] Safe mode yapılandırma (ping hedefi, aktif/pasif)
- [ ] API zaman aşımı ve paralel sorgu ayarları
- [ ] [Tüm Route'ları Temizle (Flush)]
- [ ] [Fabrika Ayarlarına Dön]
- [ ] [Yapılandırmayı Yedekle] / [Yapılandırmayı Geri Yükle]
- [ ] Sürüm bilgisi ve güncelleme kontrolü

**8.5 Provider Ayarları — Gelişmiş** *(Bölüm 8.5)*:
- [ ] Sürükle-bırak ile provider öncelik sıralaması
- [ ] Başarı oranı ve ortalama yanıt süresi göstergesi
- [ ] Fallback stratejisi seçimi (sıralı / paralel / sadece önbellek)
- [ ] [Tüm Önbelleği Temizle]
- [ ] [Tümünü Test Et] — her provider'a test sorgusu

**Kilometre Taşı**: Tüm 7 LuCI sayfası tam özellikli çalışır, terminal bilmeyen kullanıcı her işlemi web'den yapabilir.

---

### Faz 6: Gelişmiş Özellikler ve Dağıtım

İkincil hedefler *(Bölüm 3.2)* ve topluluk dağıtımı.

**DNS Bazlı Routing** *(Bölüm 3.2)*:
- [ ] dnsmasq nftset/ipset entegrasyonu
- [ ] Domain bazlı kural tanımlama (`option domain 'netflix.com'`)
- [ ] DNS yanıtlarından dinamik IP çözümleme ve set'e ekleme

**Ülke Bazlı Routing** *(Bölüm 3.2)*:
- [ ] Ülke kodu ile toplu ASN ekleme (`mergen add --country TR --via wg0`)
- [ ] Ülke -> ASN eşleme veritabanı (MaxMind GeoLite2 Country)
- [ ] LuCI'de ülke seçici (dropdown ile ülke bazlı kural ekleme)

**Trafik İstatistikleri** *(Bölüm 3.2)*:
- [ ] nftables sayaçları ile kural başına paket/byte sayımı
- [ ] LuCI'de kural başına trafik göstergesi
- [ ] Zaman serisi veri toplama (opsiyonel, collectd entegrasyonu)

**Failover / Health Check** *(Bölüm 3.2, 8.4)*:
- [ ] Hedef arayüz sağlık kontrolü (periyodik ping)
- [ ] Arayüz düştüğünde trafiği alternatif arayüze yönlendirme
- [ ] Arayüz geldiğinde orijinal kurala geri dönme
- [ ] LuCI'de failover yapılandırması ve durum gösterimi

**mwan3 Entegrasyonu** *(Bölüm 3.1)*:
- [ ] Mevcut mwan3 kuralları ile çatışma kontrolü
- [ ] mwan3 policy'lerine Mergen kural enjeksiyonu
- [ ] Standalone / mwan3 modu seçimi

**Performans ve Platform Doğrulama** *(Bölüm 12)*:
- [ ] Performans stres testi: 50.000 prefix, 100+ kural *(Bölüm 11)*
- [ ] Platform testleri: x86 VM, Raspberry Pi (arm), GL.iNet (mips)
- [ ] OpenWrt 23.05 ve 24.xx sürüm uyumluluk (regresyon) testleri
- [ ] E2E testler (LuCI'den kural ekle -> trafik doğrula)

**Dağıtım** *(Bölüm 15)*:
- [ ] OpenWrt paket feed'ine PR gönderimi
- [ ] Kullanıcı dokümantasyonu (kurulum, yapılandırma, CLI referans)
- [ ] OpenWrt forum duyurusu ve topluluk geri bildirim döngüsü

**Kilometre Taşı**: Tüm birincil ve ikincil hedefler tamamlanır, OpenWrt paket deposunda yayınlanır.

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
