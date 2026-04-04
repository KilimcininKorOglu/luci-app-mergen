# Mergen Sorun Giderme Rehberi

[English](troubleshooting.en.md)

Bu belge, Mergen'i OpenWrt üzerinde çalıştırırken karşılaşılan yaygın sorunları,
tanı komutlarını ve çözüm adımlarını kapsamaktadır.

---

## İçindekiler

1. [Kurallar Çalışmıyor](#1-kurallar-çalışmıyor)
2. [Yüksek Bellek Kullanımı](#2-yüksek-bellek-kullanımı)
3. [Yedekleme Geçiş Sorunları](#3-yedekleme-geçiş-sorunları)
4. [Sağlayıcı Hataları](#4-sağlayıcı-hataları)
5. [mwan3 Çatışmaları](#5-mwan3-çatışmaları)
6. [Güvenli Mod ve Geri Alma](#6-güvenli-mod-ve-geri-alma)
7. [LuCI Görünmüyor](#7-luci-görünmüyor)
8. [Log Analizi](#8-log-analizi)

---

## 1. Kurallar Çalışmıyor

`mergen apply` çalıştırıldıktan sonra trafik beklenen arayüz üzerinden
yönlendirilmiyorsa, aşağıdaki kontrolleri sırasıyla yapın.

### 1.1 Mergen Durumunu Doğrulayın

Mergen daemon'unun çalıştığını ve kuralların `active` durumunda olduğunu
doğrulayın:

```sh
mergen status
```

Beklenen çıktı `Daemon: active` ifadesini ve kurallarınızın `pending` veya
`failed` yerine `active` olarak listelenmesini içerir. Daemon çalışmıyorsa
başlatmanız gerekir:

```sh
/etc/init.d/mergen start
```

Daemon başlatma başarısız olursa, init betiği çıktısını kontrol edin:

```sh
/etc/init.d/mergen start; echo "Exit code: $?"
```

### 1.2 Hedef Arayüzü Doğrulayın

`--via` seçeneğinde belirtilen arayüzün aktif olması ve geçerli bir ağ geçidine
sahip olması gerekir. Bağlantı durumunu kontrol edin:

```sh
ip link show <interface>
```

Çıktıda `state UP` gösterilmelidir. Arayüz kapalı ise standart OpenWrt
mekanizması ile aktif edin:

```sh
ifup <interface>
```

Arayüzün atanmış bir IP adresi ve varsayılan ağ geçidine sahip olduğunu
doğrulayın:

```sh
ifstatus <interface>
```

### 1.3 Yönlendirme Tablosunu Kontrol Edin

Mergen, ilke tabanlı yönlendirme için özel yönlendirme tabloları oluşturur.
Varsayılan başlangıç tablo numarası 100'dür (`default_table` UCI seçeneği ile
yapılandırılabilir). İlgili tablonun içeriğini inceleyin:

```sh
ip route show table 100
```

Tablo boş ise veya beklenen rotalar eksikse, kuralları yeniden uygulayın:

```sh
mergen apply
```

Mergen'in yüklediği tüm ip kurallarını görmek için:

```sh
ip rule show | grep mergen
```

IPv6 yönlendirme tabloları için:

```sh
ip -6 route show table 100
ip -6 rule show | grep mergen
```

### 1.4 nftables / ipset Kümelerini İnceleyin

Mergen, verimli ön ek eşleştirme için nftables kümeleri (veya eski sistemlerde
ipset) kullanır. Kümelerin doldurulduğunu doğrulayın:

**nftables (varsayılan):**

```sh
nft list table inet mergen
```

Bu komut, kurallarınızın adıyla adlandırılan kümeleri (örneğin
`mergen_cloudflare`) beklenen eleman sayısıyla göstermelidir. Belirli bir kümeyi
incelemek için:

```sh
nft list set inet mergen mergen_cloudflare
```

**ipset (eski sistemler):**

```sh
ipset list | grep mergen
ipset list mergen_cloudflare
```

Kümeler mevcutsa ancak boşsa, ASN çözümleyici başarısız olmuş olabilir.
Sağlayıcı durumunu kontrol edin:

```sh
mergen diag
```

### 1.5 Alan Adı Kuralları İçin DNS Çözümlemesini Doğrulayın

Alan adı tabanlı kurallarınız varsa, Mergen dnsmasq entegrasyonuna
(ipset/nftset) bağlıdır. dnsmasq'in doğru yapılandırıldığını doğrulayın:

```sh
cat /tmp/dnsmasq.d/mergen.conf
```

dnsmasq'in Mergen yapılandırması yüklü olarak çalıştığını doğrulayın:

```sh
pgrep dnsmasq
```

Kural setinizdeki bir alan adı için DNS çözümlemesini test edin:

```sh
nslookup example.com 127.0.0.1
```

dnsmasq Mergen yapılandırmasını almıyorsa, yeniden başlatın:

```sh
/etc/init.d/dnsmasq restart
```

---

## 2. Yüksek Bellek Kullanımı

Mergen, ön ek listelerini çekirdek belleğinde nftables kümelerinde (veya
ipset'lerde) depolar. Ülke tabanlı kurallar ve büyük ASN'ler on binlerce ön ek
üretebilir.

### 2.1 Mevcut Ön Ek Sayılarını Kontrol Edin

```sh
mergen status
```

Çıktı, hem IPv4 hem de IPv6 için toplam ön ek sayılarını raporlar. Kural başına
ön ek sayılarını inceleyin:

```sh
mergen list
```

Çok yüksek ön ek sayılarına sahip kurallar (örneğin büyük ülkeler için ülke
tabanlı kurallar) bellek baskısının en yaygın nedenidir.

### 2.2 Ön Ek Limitlerini Azaltın

Mergen, kaynak tükenmesini önlemek için iki limit uygular:

| UCI Seçeneği             | Açıklama                                    | Varsayılan |
|--------------------------|---------------------------------------------|------------|
| `prefix_limit`           | Tek bir kural başına maksimum ön ek sayısı  | 10000      |
| `total_prefix_limit`     | Tüm kurallar genelinde maksimum ön ek sayısı | 50000      |

Bu limitleri düşürmek için:

```sh
uci set mergen.global.prefix_limit='5000'
uci set mergen.global.total_prefix_limit='25000'
uci commit mergen
mergen apply
```

### 2.3 Ülke Tabanlı Kuralları En Aza İndirin

Tek bir `--country` kuralı, her birinde yüzlerce ön ek bulunan binlerce ASN'ye
çözümlenebilir. Bellek tüketimini azaltma stratejileri:

- Geniş ülke kurallarını, ihtiyaç duyduğunuz belirli hizmetler için hedefli ASN
  kuralları ile değiştirin.
- Aktif ülke kuralı sayısını azaltın.
- Çift yığın yönlendirme gerekmiyorsa IPv6'yı devre dışı bırakın:

```sh
uci set mergen.global.ipv6_enabled='0'
uci commit mergen
mergen apply
```

### 2.4 Sistem Belleğini İzleyin

```sh
free -m
cat /proc/meminfo | grep -E 'MemTotal|MemFree|MemAvailable'
```

32 MB'lik bir cihazda kullanılabilir bellek 10 MB'nin altına düştüyse, kural
setinizi azaltın veya ön ek limitlerini yalnızca donanım destekliyorsa artırın.

---

## 3. Yedekleme Geçiş Sorunları

Mergen, otomatik yedekleme geçişini destekler: birincil arayüz kapandığında
trafik, yapılandırılmış yedek arayüz üzerinden yeniden yönlendirilir.

### 3.1 Yedek Yapılandırmasını Doğrulayın

Kuralın tanımlanmış bir yedek arayüzüne sahip olduğunu doğrulayın:

```sh
mergen show <rule_name>
```

Çıktı bir `fallback` alanı içermelidir. Eksikse ekleyin:

```sh
mergen add --asn 13335 --via wg0 --fallback wan --name cloudflare
```

### 3.2 Yedek Arayüzünün Aktif Olduğunu Doğrulayın

```sh
ip link show <fallback_interface>
ifstatus <fallback_interface>
```

Yedekleme geçişinin başarılı olabilmesi için yedek arayüzün aktif olması ve
geçerli bir ağ geçidine sahip olması gerekir.

### 3.3 Gözetleyiciyi Kontrol Edin

Gözetleyici daemon'u arayüz sağlık izlemesini yönetir ve yedekleme geçişini
tetikler. Çalıştığını doğrulayın:

```sh
ps | grep mergen-watchdog
```

Çalışmıyorsa, gözetleyicinin yapılandırmada etkinleştirildiğini kontrol edin:

```sh
uci get mergen.global.watchdog_enabled
```

Gerekirse gözetleyiciyi başlatın:

```sh
/etc/init.d/mergen start
```

### 3.4 Yedekleme Geçiş Durum Dizinini İnceleyin

Mergen, yedekleme geçiş durumunu `/tmp/mergen/failover/` dizininde takip eder.
Her arayüzün bir durum dosyası vardır:

```sh
ls -la /tmp/mergen/failover/
cat /tmp/mergen/failover/<interface>
```

Durum dosyası eski veya bozuksa, temizleyip gözetleyiciyi yeniden başlatmak
sorunu çözebilir:

```sh
rm -rf /tmp/mergen/failover/
/etc/init.d/mergen restart
```

### 3.5 Arayüz Erişimini Test Edin

Gözetleyicinin ping hedefine her arayüz üzerinden erişilebildiğini doğrulayarak
bir yedekleme geçiş senaryosu simüle edin:

```sh
ping -I <primary_interface> -c 3 8.8.8.8
ping -I <fallback_interface> -c 3 8.8.8.8
```

---

## 4. Sağlayıcı Hataları

Mergen, takılabilen ASN veri sağlayıcıları kullanır (RIPE RIS, bgp.tools,
bgpview.io, MaxMind, RouteViews, IRR/RADB). Ön ek çözümlemesi başarısız olursa,
şu adımları izleyin.

### 4.1 Sağlayıcıları Doğrulayın

Yerleşik sağlayıcı doğrulamasını çalıştırın:

```sh
mergen validate --check-providers
```

Bu, her etkin sağlayıcı için bağlantı ve yanıt formatını test eder.

### 4.2 İnternet Bağlantısınızı Kontrol Edin

Sağlayıcılar, giden HTTPS erişimi gerektirir. Temel bağlantıyı doğrulayın:

```sh
ping -c 3 8.8.8.8
wget -q -O /dev/null https://stat.ripe.net/ && echo "RIPE reachable" || echo "RIPE unreachable"
```

DNS çözümlemesi başarısız oluyorsa:

```sh
nslookup stat.ripe.net
nslookup bgp.tools
```

### 4.3 Sağlayıcı Tanısını Çalıştırın

```sh
mergen diag
```

Bu, yapılandırılmış her sağlayıcı için sağlık durumunu, yanıt süresini ve başarı
oranını görüntüler. Zaman aşımı veya HTTP hataları raporlayan sağlayıcıları
arayın.

### 4.4 Belirli Bir ASN Çözümlemesini Test Edin

```sh
mergen resolve 13335
```

Birincil sağlayıcı başarısız olursa, Mergen otomatik olarak öncelik sırasındaki
bir sonraki sağlayıcıya geçer. Çıktı, hangi sağlayıcının kullanıldığını
belirtir. Tüm sağlayıcılar başarısız olursa, şu kontrolleri yapın:

- Giden HTTPS (port 443) bağlantılarını engelleyen güvenlik duvarı kuralları.
- Yönlendirici bir proxy arkasındaysa proxy ayarları.
- Sağlayıcıya özel hız sınırları (RIPE ve bgpview.io sınır uygular).

### 4.5 Sağlayıcı Önceliği Ayarlayın

Bir sağlayıcı sürekli olarak yavaş veya güvenilmezse, önceliği düşürün veya
devre dışı bırakın:

```sh
uci set mergen.ripe.priority='99'
uci set mergen.bgptools.priority='10'
uci commit mergen
```

### 4.6 Sağlayıcı Önbelleğini Temizleyin

Eski önbellek girdileri beklenmedik davranışlara neden olabilir:

```sh
rm -rf /tmp/mergen/cache/*
mergen update
```

---

## 5. mwan3 Çatışmaları

Mergen, bağımsız modda çalışabilir veya çoklu WAN yük dengeleme için mwan3 ile
entegre olabilir. Her iki araç da çakışan yönlendirme tabloları veya ip
kurallarını yönettiğinde çatışmalar ortaya çıkar.

### 5.1 mwan3 Çatışmalarını Teşhis Edin

mwan3'e özel tanıyı çalıştırın:

```sh
mergen diag --mwan3
```

Bu, Mergen ve mwan3 arasındaki çakışan yönlendirme tablo numaralarını, çatışan
ip kurallarını ve ilke çatışmalarını kontrol eder.

### 5.2 Varsayılan Yönlendirme Tablosunu Ayarlayın

Mergen ve mwan3 aynı yönlendirme tablo numaralarını kullanıyorsa, Mergen
varsayılanını değiştirin:

```sh
# Mevcut Mergen tablosunu kontrol edin
uci get mergen.global.default_table

# mwan3 tablolarını kontrol edin
ip rule show | grep mwan

# Mergen'i çakışmayan bir aralığa ayarlayın
uci set mergen.global.default_table='200'
uci commit mergen
mergen flush
mergen apply
```

### 5.3 mwan3 Moduna Geçin

Mergen'in rotaları bağımsız olarak yönetmek yerine kurallarını mwan3
ilkelerine enjekte etmesini istiyorsanız, mwan3 entegrasyon moduna geçmeyi
düşünün. Bu, rota yönetimini mwan3'e devrederek tablo çatışmalarını tamamen
önler:

```sh
uci set mergen.global.mode='mwan3'
uci commit mergen
mergen apply
```

### 5.4 Çakışan Kuralları İnceleyin

Çatışmaları belirlemek için her iki aracın tüm ip kurallarını listeleyin:

```sh
ip rule show
```

Tekrarlayan tablo referansları veya aynı öncelik düzeyindeki kuralları arayın.
Mergen kuralları, yorum etiketi ile tanımlanabilir.

---

## 6. Güvenli Mod ve Geri Alma

Mergen, yanlış kurallar uygulandıktan sonra erişim kaybını önleyen bir güvenli
mod mekanizması içerir. `mergen apply --safe` kullanıldığında, sistem
değişiklikleri kalıcı yapmadan önce açık onay bekler.

### 6.1 Değişiklikleri Onaylama

`mergen apply --safe` komutundan sonra, onaylamak için sınırlı bir süreniz vardır
(varsayılan: 60 saniye):

```sh
mergen confirm
```

Zaman aşımı süresi içinde `mergen confirm` çalıştırmazsanız, gözetleyici tüm
değişiklikleri otomatik olarak önceki duruma geri alır.

### 6.2 Manuel Geri Alma

Kurallar güvenli mod olmadan uygulanmışsa ancak sorunlara neden oluyorsa, önceki
duruma manuel olarak geri dönün:

```sh
mergen rollback
```

Bu, yönlendirme tablolarını, nftables kümelerini ve ip kurallarını son
`mergen apply` öncesindeki duruma geri yükler.

### 6.3 Gözetleyici Otomatik Geri Alma

Gözetleyici, bir uygulama işleminden sonra bağlantıyı izler. Yapılandırılmış
ping hedefi erişilemez hâle gelirse, otomatik geri alma tetiklenir. Ping hedefi
yapılandırmasını kontrol edin:

```sh
uci get mergen.global.safe_mode_ping_target
```

Varsayılan hedef `8.8.8.8`'dir. Ağınız bu adrese sınırsız erişime sahip değilse
değiştirin:

```sh
uci set mergen.global.safe_mode_ping_target='1.1.1.1'
uci commit mergen
```

### 6.4 Onay Zaman Aşımını Ayarlama

Gözetleyici zaman aşımını (saniye cinsinden) değiştirmek için:

```sh
uci set mergen.global.watchdog_interval='120'
uci commit mergen
```

### 6.5 Acil Durum Kurtarma

Kurallar uygulandıktan sonra SSH erişimi kaybedilirse, yönlendiriciyi yeniden
başlatın. Mergen, onaylanmamış değişiklikleri yeniden başlatmalar arasında
korumaz, bu nedenle önceki çalışan durum otomatik olarak geri yüklenir.

Yönlendirici SSH ile erişilemezse:

1. Gözetleyici zaman aşımının dolmasını bekleyin (varsayılan: 60 saniye).
2. Otomatik geri alma erişimi geri yüklemezse, fiziksel bir yeniden başlatma yapın.
3. Yeniden başlatmadan sonra durumu doğrulayın: `mergen status`

---

## 7. LuCI Görünmüyor

Kurulumdan sonra LuCI web arayüzünde Mergen sekmesi görünmüyorsa, şu adımları
izleyin.

### 7.1 Paketin Kurulu Olduğunu Doğrulayın

```sh
opkg list-installed | grep luci-app-mergen
```

Paket listede yoksa kurun:

```sh
opkg update
opkg install luci-app-mergen
```

### 7.2 Tarayıcı Önbelleğini Temizleyin

LuCI, JavaScript ve CSS dosyalarını agresif şekilde önbelleğe alır. Tarayıcı
önbelleğinizi temizleyin veya zorla yenileme yapın (Ctrl+Shift+R / Cmd+Shift+R).

### 7.3 Web Sunucusunu Yeniden Başlatın

```sh
/etc/init.d/uhttpd restart
```

Yeniden başlatmadan sonra, tarayıcınızda LuCI arayüzünü yeniden yükleyin.

### 7.4 LuCI Hatalarını Kontrol Edin

Sekme görünüyor ancak sayfa yüklenemiyorsa, Lua hatalarını kontrol edin:

```sh
logread | grep -i luci
logread | grep -i mergen
```

### 7.5 Dosya İzinlerini Doğrulayın

LuCI denetleyici ve görünüm dosyalarının doğru izinlere sahip olduğunu
doğrulayın:

```sh
ls -la /usr/lib/lua/luci/controller/mergen.lua
ls -la /usr/lib/lua/luci/model/cbi/mergen*.lua
ls -la /usr/lib/lua/luci/view/mergen/
```

Tüm dosyalar okunabilir olmalıdır (en az mod 0644).

---

## 8. Log Analizi

Mergen, önem derecesi ve bileşen adı içeren yapılandırılmış loglar yazar.
Etkili log analizi, çoğu sorunun teşhisinde en hızlı yoldur.

### 8.1 Son Logları Görüntüleyin

Son 50 hata düzeyindeki log girdisini görüntüleyin:

```sh
mergen log --tail 50 --level error
```

En şiddetliden en aza doğru mevcut log düzeyleri: `error`, `warning`, `info`,
`debug`.

Tüm log düzeylerini görüntülemek için:

```sh
mergen log --tail 100 --level debug
```

### 8.2 Bileşene Göre Filtreleyin

Mergen logları bileşene göre etiketlenir (resolver, engine, route, provider,
daemon). Filtrelemek için:

```sh
mergen log --tail 50 --level info | grep resolver
mergen log --tail 50 --level info | grep provider
```

### 8.3 Sistem Logunu Kontrol Edin

Mergen ayrıca syslog üzerinden OpenWrt sistem loguna da yazar:

```sh
logread | grep mergen
```

Gerçek zamanlı izleme için:

```sh
logread -f | grep mergen
```

### 8.4 Yaygın Log Mesajları ve Anlamları

| Log Mesajı                                  | Anlamı                                              | Eylem                                            |
|---------------------------------------------|-----------------------------------------------------|--------------------------------------------------|
| `provider timeout`                          | ASN sağlayıcısı son tarih içinde yanıt vermedi      | İnternet bağlantısını kontrol edin; sonraki sağlayıcıyı deneyin |
| `prefix limit exceeded`                     | Bir kural izin verilenden fazla ön ek çözümledi      | `prefix_limit` değerini artırın veya kural kapsamını daraltın |
| `interface down, failover triggered`        | Birincil arayüz bağlantısını kaybetti                | Arayüz durumunu ve kabloları kontrol edin        |
| `rollback: connectivity check failed`       | Uygulama sonrası güvenli mod ping'i başarısız oldu   | Uygulanan kuralların doğruluğunu gözden geçirin  |
| `lock acquisition failed`                   | Başka bir Mergen süreci kilidi tutuyor                | Bekleyin ve tekrar deneyin veya eski kilitleri kontrol edin |
| `nft set creation failed`                   | nftables bir küme oluşturma hatası raporladı          | nftables sürüm uyumluluğunu kontrol edin         |

### 8.5 Tanı Paketi Oluşturun

Sorun bildirmek için, logları, yapılandırmayı ve sistem durumunu içeren tam bir
tanı paketi oluşturun:

```sh
mergen diag > /tmp/mergen-diag.txt
```

Bu çıktı şunları içerir:

- Mergen sürümü ve yapılandırması
- Sağlayıcı sağlık durumu
- Aktif kurallar ve ön ek sayıları
- Yönlendirme tablosu içerikleri
- nftables/ipset küme özetleri
- Son log girdileri
- Sistem belleği ve OpenWrt sürümü

Sorunları üst kaynaklara bildirirken bu dosyayı ekleyin.

### 8.6 Eski Kilit Dosyalarını Kontrol Edin

Mergen komutları takılıyorsa veya kilit hataları raporluyorsa, önceki bir süreç
kilidi serbest bırakmadan sonlanmış olabilir:

```sh
ls -la /var/lock/mergen.lock
```

Kilit dosyası mevcutsa ancak sahip süreç artık çalışmıyorsa:

```sh
rm /var/lock/mergen.lock
```

Ardından komutunuzu yeniden deneyin.

---

## Hızlı Başvuru: Tanı Komutları

| Amaç                               | Komut                                       |
|------------------------------------|---------------------------------------------|
| Genel durum                        | `mergen status`                             |
| Tüm kuralları listele              | `mergen list`                               |
| Kural detayı göster                | `mergen show <name>`                        |
| Sağlayıcı sağlığı                 | `mergen diag`                               |
| Yapılandırmayı doğrula            | `mergen validate`                           |
| Sağlayıcıları doğrula             | `mergen validate --check-providers`         |
| mwan3 çatışmalarını kontrol et    | `mergen diag --mwan3`                       |
| Hata loglarını görüntüle          | `mergen log --tail 50 --level error`        |
| Sistem logu                        | `logread \| grep mergen`                    |
| Yönlendirme tablosu               | `ip route show table 100`                   |
| IPv6 yönlendirme tablosu          | `ip -6 route show table 100`               |
| IP kuralları                       | `ip rule show`                              |
| nftables kümeleri                  | `nft list table inet mergen`                |
| Arayüz durumu                     | `ip link show <iface>`                      |
| Yedekleme geçiş durumu            | `ls -la /tmp/mergen/failover/`              |
| Güvenli modu onayla               | `mergen confirm`                            |
| Son uygulamayı geri al            | `mergen rollback`                           |
| Tüm Mergen rotalarını temizle     | `mergen flush`                              |
| Sağlayıcı önbelleğini temizle     | `rm -rf /tmp/mergen/cache/*`                |
| Mergen'i yeniden başlat           | `/etc/init.d/mergen restart`                |
| LuCI web sunucusunu yeniden başlat | `/etc/init.d/uhttpd restart`                |
