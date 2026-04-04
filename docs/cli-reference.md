# Mergen CLI Referansı

[English](cli-reference.en.md)

Mergen, OpenWrt için ASN/IP tabanlı politika yönlendirme aracıdır. ASN ön eklerini otomatik olarak çözümler ve trafiği belirlenen ağ arayüzleri üzerinden yönlendirmek için `ip rule`, `ip route` ve `nftables`/`ipset` girişlerini yönetir.

Tüm komutlar root yetkisi gerektirir.

```
mergen <komut> [seçenekler]
```

---

## İçindekiler

- [add](#add)
- [remove](#remove)
- [list](#list)
- [show](#show)
- [enable](#enable)
- [disable](#disable)
- [apply](#apply)
- [flush](#flush)
- [rollback](#rollback)
- [confirm](#confirm)
- [status](#status)
- [diag](#diag)
- [log](#log)
- [validate](#validate)
- [tag](#tag)
- [update](#update)
- [import](#import)
- [export](#export)
- [resolve](#resolve)
- [version](#version)
- [help](#help)

---

## add

Yeni bir politika yönlendirme kuralı oluşturur. Her kural, bir hedef kümesini (ASN ön ekleri, IP/CIDR blokları, alan adları veya ülke bazlı ASN'ler) bir hedef ağ arayüzüne bağlar.

**Sözdizimi**

```
mergen add --name <AD> (--asn <ASN> | --ip <CIDR> | --domain <FQDN> | --country <CC>) --via <ARAYÜZ> [--priority <N>] [--fallback <ARAYÜZ>]
```

**Seçenekler**

| Seçenek                  | Zorunlu  | Açıklama                                                                                         |
|--------------------------|----------|--------------------------------------------------------------------------------------------------|
| `--name <AD>`            | Evet     | Kural için benzersiz, okunabilir bir tanımlayıcı.                                                |
| `--asn <ASN>`            | Hayır*   | Otonom Sistem Numarası. Mergen bu ASN için duyurulan tüm ön ekleri otomatik olarak çözümler.     |
| `--ip <CIDR>`            | Hayır*   | CIDR gösteriminde IPv4 veya IPv6 adres bloğu (örneğin `185.70.40.0/22`).                        |
| `--domain <FQDN>`        | Hayır*   | Tam nitelikli alan adı. dnsmasq nftset/ipset entegrasyonu ile çözümlenir.                        |
| `--country <CC>`         | Hayır*   | ISO 3166-1 alpha-2 ülke kodu (örneğin `TR`, `US`). O ülkede kayıtlı tüm ASN'leri ekler.        |
| `--via <ARAYÜZ>`         | Evet     | Eşleşen trafik için hedef ağ arayüzü (örneğin `wg0`, `wan2`, `lan`).                            |
| `--priority <N>`         | Hayır    | Yönlendirme kuralı önceliği. Düşük değerler önce değerlendirilir. Varsayılan: `100`. Aralık: `1`--`32000`. |
| `--fallback <ARAYÜZ>`    | Hayır    | Birincil `--via` arayüzü devre dışı kaldığında kullanılan yedek arayüz.                         |

\* `--asn`, `--ip`, `--domain` veya `--country` seçeneklerinden tam olarak biri zorunludur.

**Örnekler**

```bash
# Tüm Cloudflare (AS13335) trafiğini bir WireGuard tüneli üzerinden yönlendir
mergen add --name cloudflare --asn 13335 --via wg0

# Belirli bir alt ağı ikincil WAN üzerinden yönlendir
mergen add --name office-vpn --ip 10.0.0.0/8 --via wan2 --priority 50

# Bir alan adını DNS tabanlı çözümleme ile VPN üzerinden yönlendir
mergen add --name protonmail --domain protonmail.com --via wg0

# Türkiye'de kayıtlı tüm ASN'leri varsayılan WAN üzerinden yönlendir
mergen add --name turkey-direct --country TR --via wan

# Yedekli yönlendirme: wg0 kullan, tünel düşerse wan'a geç
mergen add --name google --asn 15169 --via wg0 --fallback wan --priority 200
```

---

## remove

Mevcut bir kuralı ada göre siler. Bu, kuralı UCI yapılandırmasından kaldırır. Kuralın rotaları bir sonraki `mergen apply` veya `mergen flush` işlemine kadar aktif kalır.

**Sözdizimi**

```
mergen remove <AD>
```

**Argümanlar**

| Argüman  | Zorunlu  | Açıklama                        |
|----------|----------|---------------------------------|
| `<AD>`   | Evet     | Silinecek kuralın adı.          |

**Örnekler**

```bash
# "cloudflare" adlı kuralı sil
mergen remove cloudflare

# Sil ve eski rotaları temizlemek için hemen yeniden uygula
mergen remove office-vpn && mergen apply
```

---

## list

Yapılandırılmış tüm kuralları bir özet tablosu olarak görüntüle.

**Sözdizimi**

```
mergen list
```

**Çıktı Sütunları**

| Sütun  | Açıklama                                                       |
|--------|----------------------------------------------------------------|
| ID     | Sıra numarası.                                                |
| NAME   | Kural adı.                                                    |
| TYPE   | Kural tipi: `ASN`, `IP`, `DOMAIN` veya `COUNTRY`.             |
| TARGET | ASN numarası, CIDR bloğu, alan adı veya ülke kodu.            |
| VIA    | Hedef arayüz.                                                 |
| PRI    | Öncelik değeri.                                                |
| STATUS | Mevcut durum: `active`, `pending`, `disabled` veya `failed`.  |

**Örnekler**

```bash
mergen list
```

```
ID  NAME         TYPE     TARGET              VIA   PRI  STATUS
1   cloudflare   ASN      AS13335 (847 pfx)   wg0   100  active
2   protonmail   IP       185.70.40.0/22      wg0   100  pending
3   google       ASN      AS15169 (1203 pfx)  wg0   200  active
4   turkey       COUNTRY  TR (412 ASNs)       wan   300  disabled
```

---

## show

Tek bir kural hakkında çözümlenmiş ön ek listesi, arayüz bağlantısı ve mevcut işletme durumu dahil ayrıntılı bilgi görüntüler.

**Sözdizimi**

```
mergen show <AD>
```

**Argümanlar**

| Argüman  | Zorunlu  | Açıklama                        |
|----------|----------|---------------------------------|
| `<AD>`   | Evet     | İncelenecek kuralın adı.       |

**Örnekler**

```bash
mergen show cloudflare
```

```
Rule:       cloudflare
Type:       ASN
ASN:        13335
Via:        wg0
Fallback:   wan
Priority:   100
Status:     active
Enabled:    yes
Tags:       cdn, vpn-routed
Table:      100
Prefixes:   847 total (612 IPv4, 235 IPv6)
Last Sync:  2026-04-03 14:30:00 UTC
Provider:   ripe

IPv4 Prefixes (first 10):
  104.16.0.0/13
  104.24.0.0/14
  172.64.0.0/13
  ...
```

---

## enable

Daha önce devre dışı bırakılmış bir kuralı veya bir etikete uyan tüm kuralları aktif hale getirir. Etkinleştirilen kurallar bir sonraki `mergen apply` işlemine dahil edilir.

**Sözdizimi**

```
mergen enable <AD>
mergen enable --tag <ETİKET>
```

**Seçenekler**

| Seçenek            | Açıklama                                                  |
|--------------------|-----------------------------------------------------------|
| `<AD>`             | Etkinleştirilecek kuralın adı.                            |
| `--tag <ETİKET>`   | Belirtilen etiketi taşıyan tüm kuralları etkinleştirir.   |

**Örnekler**

```bash
# Tek bir kuralı etkinleştir
mergen enable cloudflare

# "vpn-routed" etiketli tüm kuralları etkinleştir
mergen enable --tag vpn-routed
```

---

## disable

Bir kuralı veya bir etikete uyan tüm kuralları devre dışı bırakır. Devre dışı bırakılan kurallar yönlendirmeden hariç tutulur ancak yapılandırmada kalır.

**Sözdizimi**

```
mergen disable <AD>
mergen disable --tag <ETİKET>
```

**Seçenekler**

| Seçenek            | Açıklama                                                       |
|--------------------|----------------------------------------------------------------|
| `<AD>`             | Devre dışı bırakılacak kuralın adı.                            |
| `--tag <ETİKET>`   | Belirtilen etiketi taşıyan tüm kuralları devre dışı bırakır.  |

**Örnekler**

```bash
# Tek bir kuralı devre dışı bırak
mergen disable google

# "streaming" etiketli tüm kuralları devre dışı bırak
mergen disable --tag streaming
```

---

## apply

Etkinleştirilmiş tüm kuralları sistem yönlendirme girişlerine (`ip rule`, `ip route`, `nftables` kümeleri) derler ve atomik olarak uygular. Herhangi bir kural uygulanamaz ise tüm işlem otomatik olarak geri alınır.

**Sözdizimi**

```
mergen apply [--force] [--safe]
```

**Seçenekler**

| Seçenek   | Açıklama                                                                                                  |
|-----------|-----------------------------------------------------------------------------------------------------------|
| `--force` | Ön ek sayısı sınırlarını atlar ve eşikler aşılsa bile uygular.                                            |
| `--safe`  | Güvenli modu etkinleştirir: uygulamadan sonra Mergen bağlantı testi (ping) yapar. Test 60 saniye içinde başarısız olursa tüm değişiklikler otomatik olarak geri alınır. |

**Örnekler**

```bash
# Standart uygulama
mergen apply

# Ön ek sayısı uyarılarını yok sayarak zorla uygula
mergen apply --force

# Bağlantı kaybı durumunda otomatik geri alma ile güvenli uygulama
mergen apply --safe
```

**Güvenli Mod Davranışı**

`--safe` kullanıldığında Mergen aşağıdaki sırayı izler:

1. Mevcut yönlendirme durumunun bir anlık görüntüsünü alır.
2. Bekleyen tüm kuralları uygular.
3. Yapılandırılmış güvenli mod hedefine ping atar (varsayılan: `8.8.8.8`).
4. Ping başarılı olursa yeni durum onaylanır.
5. Ping başarısız olursa veya 60 saniye içinde `mergen confirm` alınmazsa Mergen otomatik olarak anlık görüntüye geri döner.

---

## flush

Çalışan sistemden Mergen tarafından yönetilen tüm rotaları, `ip rule` girişlerini ve `nftables`/`ipset` kümelerini kaldırır. Kurallar UCI yapılandırmasında kalır ve `mergen apply` ile yeniden uygulanabilir.

**Sözdizimi**

```
mergen flush [--confirm]
```

**Seçenekler**

| Seçenek     | Açıklama                                                          |
|-------------|-------------------------------------------------------------------|
| `--confirm` | Etkileşimli onay istemini atlar. Betik kullanımı için gereklidir. |

**Örnekler**

```bash
# Etkileşimli temizleme (onay ister)
mergen flush

# Betikler için etkileşimsiz temizleme
mergen flush --confirm
```

---

## rollback

En son `mergen apply` işleminden önce alınan yönlendirme durumu anlık görüntüsüne geri döner. Bu, tüm `ip rule`, `ip route` ve `nftables` küme girişlerini önceki durumlarına geri yükler.

**Sözdizimi**

```
mergen rollback
```

**Örnekler**

```bash
# Son uygulamayı geri al
mergen rollback
```

---

## confirm

Bir `mergen apply --safe` işleminden sonra mevcut yönlendirme durumunu onaylar. Bu, otomatik geri alma zamanlayıcısının değişiklikleri geri almasını engeller.

**Sözdizimi**

```
mergen confirm
```

**Örnekler**

```bash
# Güvenli modda uygula, ardından bağlantıyı doğruladıktan sonra onayla
mergen apply --safe
# ... SSH/web erişiminin hala çalıştığını doğrulayın ...
mergen confirm
```

---

## status

Mergen sisteminin mevcut işletme durumunu görüntüler; arka plan süreci durumu, kural sayıları, ön ek toplamları ve eşzamanlama zaman damgaları dahildir.

**Sözdizimi**

```
mergen status [--traffic]
```

**Seçenekler**

| Seçenek     | Açıklama                                                              |
|-------------|-----------------------------------------------------------------------|
| `--traffic` | Varsa kural başına trafik sayaçlarını (bayt/paket) dahil eder.        |

**Örnekler**

```bash
mergen status
```

```
Mergen v1.0.0 | OpenWrt 23.05.3
Daemon:    active (pid 1234)
Rules:     3 active, 1 pending, 0 failed
Prefixes:  2463 total (1826 IPv4, 637 IPv6)
Last sync: 2026-04-03 14:30:00 UTC
Next sync: 2026-04-04 14:30:00 UTC
```

```bash
mergen status --traffic
```

```
Mergen v1.0.0 | OpenWrt 23.05.3
Daemon:    active (pid 1234)
Rules:     3 active, 1 pending, 0 failed
Prefixes:  2463 total (1826 IPv4, 637 IPv6)
Last sync: 2026-04-03 14:30:00 UTC
Next sync: 2026-04-04 14:30:00 UTC

RULE          VIA   PACKETS    BYTES
cloudflare    wg0   145832     198.4 MB
google        wg0   87210      112.7 MB
office-vpn    wan2  3201       1.8 MB
```

---

## diag

Yönlendirme yapılandırması hakkında tanılama denetimleri çalıştırır ve hata ayıklama bilgisi çıktılar. Kural uygulama hataları, sağlayıcı bağlantısı ve mwan3 entegrasyon sorunlarını gidermek için kullanışlıdır.

**Sözdizimi**

```
mergen diag [--asn <ASN>] [--mwan3]
```

**Seçenekler**

| Seçenek       | Açıklama                                                                          |
|---------------|-----------------------------------------------------------------------------------|
| `--asn <ASN>` | Belirli bir ASN için tanılama çalıştırır: ön ekleri çözümler, rota girişlerini denetler. |
| `--mwan3`     | mwan3'e özgü tanılamaları dahil eder (politika durumu, arayüz izleme durumu).     |

Seçenek olmadan çağrıldığında `mergen diag`, yönlendirme tabloları, nftables kümeleri, arayüz durumları, sağlayıcı sağlığı ve kilit dosyası durumunu kapsayan tam bir sistem tanılama raporu çıktılar.

**Örnekler**

```bash
# Tam sistem tanılaması
mergen diag

# Belirli bir ASN için yönlendirme tanılaması
mergen diag --asn 13335

# mwan3 entegrasyon tanılamasını dahil et
mergen diag --mwan3
```

```bash
mergen diag --asn 13335
```

```
ASN Diagnostics: AS13335
  Provider:    ripe (healthy)
  Prefixes:    847 (612 IPv4, 235 IPv6)
  Cache:       fresh (age: 2h 14m)
  Route table: 100
  ip rules:    612 entries matching table 100
  nft set:     mergen_cloudflare (612 IPv4 elements)
  Ping test:   104.16.0.1 -> wg0 (ok, 12ms)
```

---

## log

Mergen günlük girişlerini syslog'dan isteğe bağlı filtreleme ile sorgular ve görüntüler.

**Sözdizimi**

```
mergen log [--tail <N>] [--level <SEVİYE>] [--component <BİLEŞEN>]
```

**Seçenekler**

| Seçenek                  | Açıklama                                                                                          |
|--------------------------|---------------------------------------------------------------------------------------------------|
| `--tail <N>`             | Yalnızca son `N` günlük girişini gösterir. Varsayılan: tüm mevcut girişler.                       |
| `--level <SEVİYE>`       | Minimum günlük seviyesine göre filtreler: `debug`, `info`, `warning`, `error`.                    |
| `--component <BİLEŞEN>`  | Bileşen adına göre filtreler: `Core`, `Engine`, `Route`, `Resolver`, `Provider`, `Daemon`, `CLI`, `NFT`, `IPSET`, `SafeMode`, `Snapshot`. |

**Örnekler**

```bash
# Son 20 günlük girişini göster
mergen log --tail 20

# Yalnızca hataları göster
mergen log --level error

# Çözümleyici ile ilgili uyarıları ve hataları göster
mergen log --level warning --component Resolver

# Route bileşeninden son 50 girişi göster
mergen log --tail 50 --component Route
```

---

## validate

Herhangi bir değişiklik uygulamadan mevcut UCI yapılandırmasını doğrular. Sözdizimi hataları, geçersiz ASN/IP değerleri, eksik arayüzler, kural çakışmaları ve ön ek sınırı ihlallerini denetler.

**Sözdizimi**

```
mergen validate [--check-providers]
```

**Seçenekler**

| Seçenek             | Açıklama                                                                        |
|---------------------|---------------------------------------------------------------------------------|
| `--check-providers` | Etkinleştirilmiş her ASN sağlayıcısına bağlantıyı da test eder (ağ erişimi gerektirir). |

**Örnekler**

```bash
# Yalnızca yapılandırmayı doğrula
mergen validate

# Yapılandırmayı doğrula ve sağlayıcı bağlantısını test et
mergen validate --check-providers
```

```bash
mergen validate
```

```
[+] Config syntax: OK
[+] Rule "cloudflare": ASN 13335 valid, interface wg0 exists
[+] Rule "office-vpn": CIDR 10.0.0.0/8 valid, interface wan2 exists
[!] Rule "broken": interface "wg99" not found. Available: wan, wg0, wan2, lan
[+] No rule conflicts detected
[+] Prefix limits: within bounds (estimated 2463 / 50000)

Result: 1 error(s), 0 warning(s)
```

```bash
mergen validate --check-providers
```

```
[+] Config syntax: OK
[+] Provider "ripe": reachable (latency: 142ms)
[!] Provider "bgptools": connection timeout (30s)
[+] Provider "bgpview": reachable (latency: 87ms)
[+] Provider "maxmind": disabled (skipped)

Result: 0 error(s), 1 warning(s)
```

---

## tag

Kurallar üzerindeki etiketleri yönetir. Etiketler, `mergen enable --tag` ve `mergen disable --tag` aracılığıyla toplu işlem yapılmasını sağlar.

**Sözdizimi**

```
mergen tag add <KURAL> <ETİKET>
mergen tag remove <KURAL> <ETİKET>
```

**Alt Komutlar**

| Alt Komut  | Açıklama                                    |
|------------|---------------------------------------------|
| `add`      | Belirtilen kurala bir etiket ekler.         |
| `remove`   | Belirtilen kuraldan bir etiketi kaldırır.   |

**Argümanlar**

| Argüman    | Zorunlu  | Açıklama                                        |
|------------|----------|-------------------------------------------------|
| `<KURAL>`  | Evet     | Etiketlenecek veya etiketi kaldırılacak kuralın adı. |
| `<ETİKET>` | Evet     | Etiket adı (alfanümerik ve tire).               |

**Örnekler**

```bash
# "cloudflare" kuralını "cdn" ile etiketle
mergen tag add cloudflare cdn

# Toplu işlemler için birden fazla kuralı etiketle
mergen tag add cloudflare vpn-routed
mergen tag add google vpn-routed

# Bir etiketi kaldır
mergen tag remove google vpn-routed
```

---

## update

Yapılandırılmış sağlayıcıları sorgulayarak etkinleştirilmiş tüm kurallar için önbelleğe alınmış ASN ön ek listelerini yeniler. İsteğe bağlı olarak güncellenen ön eklerle rotaları yeniden uygular.

**Sözdizimi**

```
mergen update [--apply]
```

**Seçenekler**

| Seçenek   | Açıklama                                                              |
|-----------|-----------------------------------------------------------------------|
| `--apply` | Ön ek güncellemesi tamamlandıktan sonra otomatik olarak `mergen apply` çalıştırır. |

**Örnekler**

```bash
# Yalnızca ön ek önbelleklerini güncelle
mergen update

# Güncelle ve yeni ön ekleri hemen uygula
mergen update --apply
```

---

## import

Bir JSON dosyasından kuralları UCI yapılandırmasına yükler. Aynı ada sahip mevcut kurallar, `--replace` belirtilmedikçe atlanır.

**Sözdizimi**

```
mergen import <dosya.json> [--replace]
```

**Argümanlar**

| Argüman        | Zorunlu  | Açıklama                          |
|----------------|----------|-----------------------------------|
| `<dosya.json>` | Evet     | JSON kural dosyasının yolu.       |

**Seçenekler**

| Seçenek     | Açıklama                                                                        |
|-------------|---------------------------------------------------------------------------------|
| `--replace` | İçe aktarılan kurallarla aynı ada sahip mevcut kuralların üzerine yazar.        |

**JSON Dosya Biçimi**

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

**Örnekler**

```bash
# Bir dosyadan kuralları içe aktar
mergen import /etc/mergen/rules.d/office.json

# Eşleşen adlara sahip mevcut kuralları üzerine yazarak içe aktar
mergen import /tmp/backup-rules.json --replace
```

---

## export

Mevcut kural yapılandırmasını JSON veya UCI biçiminde bir dosyaya dışa aktarır.

**Sözdizimi**

```
mergen export [--format <BİÇİM>] [--output <DOSYA>]
```

**Seçenekler**

| Seçenek              | Açıklama                                                                 |
|----------------------|--------------------------------------------------------------------------|
| `--format <BİÇİM>`  | Çıktı biçimi: `json` (varsayılan) veya `uci`.                           |
| `--output <DOSYA>`   | Çıktıyı stdout yerine bir dosyaya yazar. Üst dizin mevcut olmalıdır.    |

**Örnekler**

```bash
# JSON olarak stdout'a dışa aktar
mergen export

# JSON olarak bir dosyaya dışa aktar
mergen export --format json --output /tmp/mergen-rules.json

# UCI biçiminde dışa aktar
mergen export --format uci

# UCI biçimini bir dosyaya dışa aktar
mergen export --format uci --output /tmp/mergen-config.uci
```

---

## resolve

Yapılandırılmış ASN sağlayıcılarını sorgular ve herhangi bir kural oluşturmadan veya değiştirmeden verilen ASN için ön ek listesini görüntüler. Bir kural eklemeden önce bir ASN'nin hangi ön ekleri ekleyeceğini önizlemek için kullanışlıdır.

**Sözdizimi**

```
mergen resolve <ASN> [--provider <AD>]
```

**Argümanlar**

| Argüman  | Zorunlu  | Açıklama                      |
|----------|----------|-------------------------------|
| `<ASN>`  | Evet     | Otonom Sistem Numarası.       |

**Seçenekler**

| Seçenek            | Açıklama                                                                       |
|--------------------|--------------------------------------------------------------------------------|
| `--provider <AD>`  | Öncelik zinciri yerine belirli bir sağlayıcı üzerinden çözümlemeyi zorlar. Kabul edilen değerler: `ripe`, `bgptools`, `bgpview`, `maxmind`, `routeviews`, `irr`. |

**Örnekler**

```bash
# Varsayılan sağlayıcı öncelik zincirini kullanarak çözümle
mergen resolve 13335

# Belirli bir sağlayıcı üzerinden çözümlemeyi zorla
mergen resolve 13335 --provider bgptools
```

```bash
mergen resolve 13335
```

```
AS13335 (Cloudflare, Inc.)
Provider: ripe
Prefixes: 847 total (612 IPv4, 235 IPv6)

IPv4 (612):
  104.16.0.0/13
  104.24.0.0/14
  172.64.0.0/13
  ...

IPv6 (235):
  2606:4700::/32
  2803:f800::/32
  ...
```

---

## version

Yüklü Mergen sürümünü, OpenWrt dağıtımını ve etkin paket eşleştirme motorunu görüntüler.

**Sözdizimi**

```
mergen version
```

**Örnekler**

```bash
mergen version
```

```
Mergen v1.0.0
OpenWrt 23.05.3 (kernel 5.15.134)
Packet engine: nftables
```

---

## help

Genel yardımı veya belirli bir komut için ayrıntılı kullanım bilgisini görüntüler.

**Sözdizimi**

```
mergen help [<komut>]
```

**Argümanlar**

| Argüman     | Zorunlu  | Açıklama                                                                 |
|-------------|----------|--------------------------------------------------------------------------|
| `<komut>`   | Hayır    | Ayrıntılı yardım görüntülenecek komut adı. Genel yardım için atlayın.   |

**Örnekler**

```bash
# Tüm komutların listesiyle genel yardımı göster
mergen help

# "add" komutu için ayrıntılı yardımı göster
mergen help add

# "apply" komutu için ayrıntılı yardımı göster
mergen help apply
```

---

## Çıkış Kodları

Tüm Mergen komutları standart çıkış kodları döndürür:

| Kod  | Anlam                                                              |
|------|--------------------------------------------------------------------|
| `0`  | Başarılı.                                                          |
| `1`  | Genel hata (geçersiz argümanlar, eksik bağımlılıklar).            |
| `2`  | Yapılandırma hatası (geçersiz UCI yapılandırması, eksik kural).    |
| `3`  | Sağlayıcı hatası (tüm sağlayıcılar başarısız oldu, zaman aşımı). |
| `4`  | Rota uygulama hatası (çekirdek bir rotayı reddetti).               |
| `5`  | Geri alma tetiklendi (güvenli mod bağlantı testi başarısız oldu).  |

---

## Ortam

| Yol                          | Açıklama                                     |
|------------------------------|----------------------------------------------|
| `/etc/config/mergen`         | UCI yapılandırma dosyası.                    |
| `/etc/mergen/providers/`     | ASN sağlayıcı eklenti betikleri.             |
| `/etc/mergen/rules.d/`       | İçe aktarılan JSON kural dosyaları dizini.   |
| `/tmp/mergen/cache/`         | Önbelleğe alınmış ön ek listeleri (geçici).  |
| `/tmp/mergen/status.json`    | Bekçi sürecinin çalışma zamanı durumu.       |
| `/var/lock/mergen.lock`      | CLI/bekçi süreci koordinasyonu kilit dosyası. |
| `/usr/lib/mergen/`           | Çekirdek kütüphane betikleri.                |

---

## Ayrıca Bakınız

- `mergen-watchdog` -- hotplug olayları, periyodik güncellemeler ve güvenli mod izlemesi için arka plan süreci
- OpenWrt UCI belgeleri: <https://openwrt.org/docs/guide-user/base-system/uci>
- mwan3 çoklu WAN yöneticisi: <https://openwrt.org/docs/guide-user/network/wan/multiwan/mwan3>
