# Mergen LuCI Web Arayüzü Rehberi

[English](luci-guide.en.md)

Bu rehber, OpenWrt için ASN/IP tabanlı politika yönlendirme aracı olan **Mergen**'in LuCI web arayüzünü kapsar. Tüm sayfalar LuCI yönetim panelinde **Services > Mergen** altından erişilebilir.

---

## İçindekiler

1. [Genel Bakış Sayfası](#1-genel-bakış-sayfası)
2. [Kurallar Sayfası](#2-kurallar-sayfası)
3. [ASN Tarayıcı Sayfası](#3-asn-tarayıcı-sayfası)
4. [Sağlayıcılar Sayfası](#4-sağlayıcılar-sayfası)
5. [Arayüzler Sayfası](#5-arayüzler-sayfası)
6. [Kayıtlar Sayfası](#6-kayıtlar-sayfası)
7. [Gelişmiş Ayarlar Sayfası](#7-gelişmiş-ayarlar-sayfası)

---

## 1. Genel Bakış Sayfası

**Gezinme:** Services > Mergen > Overview

Genel Bakış sayfası, Mergen kurulumunuzun gerçek zamanlı panosunu sunar. Mergen arayüzünü açtığınızda varsayılan açılış sayfasıdır.

### Durum Kartları

Sayfanın üst kısmında beş durum kartı görüntülenir:

| Kart              | Açıklama                                                                      |
|:------------------|:------------------------------------------------------------------------------|
| Servis Durumu     | Mergen servisinin **Çalışıyor**, **Durduruldu** veya **Hata** durumunda olduğunu renk kodlu rozet ile gösterir (yeşil, gri veya kırmızı). |
| Toplam Kurallar   | Yapılandırılmış kuralların toplam sayısı; altında aktif ve devre dışı sayıları gösterilir. |
| Toplam Önekler    | Yüklü IPv4 öneklerinin sayısı; altında IPv4/IPv6 dağılımı gösterilir.        |
| Son Eşitleme      | En son önek verisi eşitleme zaman damgası; görece zaman göstergesi ile birlikte (örn. "2 saat önce"). |
| Sonraki Eşitleme  | Yapılandırılmış güncelleme aralığından hesaplanan bir sonraki otomatik önek güncellemesinin tahmini zamanı. |

### Aktif Kurallar Tablosu

Durum kartlarının altında, yapılandırılmış her kuralı listeleyen bir tablo yer alır:

| Sütun      | Açıklama                                                                              |
|:-----------|:--------------------------------------------------------------------------------------|
| Kural Adı  | Düzenleme için Kurallar sayfasına yönlendiren tıklanabilir ad.                        |
| Kural Tipi | Büyük harfle gösterilen kural kategorisi: ASN, IP, DOMAIN veya COUNTRY.               |
| Hedef      | Kuralın hedeflediği ASN numaraları, IP/CIDR blokları, alan adları veya ülke kodları. Uzun değerler 40 karaktere kırpılır. |
| Arayüz     | Eşleşen trafik için giden arayüz. Yedek arayüz yapılandırılmışsa birincil yanında parantez içinde görünür. |
| Öncelik    | Sayısal öncelik değeri (düşük sayılar önce işlenir).                                  |
| Trafik     | Paket sayısı ve bayt hacmini gösteren canlı trafik sayaçları (örn. "1284 pkt / 3.2 MB"). Her 15 saniyede otomatik yenilenir. |
| Durum      | Renk kodlu rozet: **aktif** (yeşil), **devre dışı** (gri) veya **yedekleme** (kırmızı) — birincil arayüz çöktüğünde ve trafik yedeğe geçtiğinde. |

### Hızlı İşlem Düğmeleri

Durum kartları ile kurallar tablosu arasında üç düğme bulunur:

- **Apply All** -- Tüm geçerli kuralları yönlendirme tablosuna anında uygular. Herhangi bir sayfada yapılandırma değişikliği yaptıktan sonra kullanın.
- **Update Prefixes** -- Yapılandırılmış tüm sağlayıcılardan isteğe bağlı önek verisi yenilemesi başlatır, ardından güncellenen rotaları uygular.
- **Restart Daemon** -- Mergen init betiğini durdurur ve yeniden başlatır. Çalıştırma öncesi onay istemi görüntülenir.

### Servis Durumu Ayrıntıları

"Daemon Status (details)" etiketli daraltılabilir bir bölüm, `mergen status` komutunun ham çıktısını içerir. Genişletmek veya daraltmak için özet başlığına tıklayın.

### Son İşlemler Günlüğü

Sayfanın alt kısmında zaman damgalı en son 10 günlük girişi gösterilir. "View all logs" bağlantısı tam Kayıtlar sayfasına yönlendirir.

### Otomatik Yenileme

Genel Bakış sayfası, sayfa yeniden yüklemesi gerektirmeden servis durumunu her 30 saniyede, trafik istatistiklerini ise her 15 saniyede otomatik olarak yeniler.

---

## 2. Kurallar Sayfası

**Gezinme:** Services > Mergen > Rules

Kurallar sayfası, yönlendirme kurallarını oluşturduğunuz, düzenlediğiniz, yeniden sıraladığınız ve kaldırdığınız yerdir. UCI'ye bağlı tablo formu kullanır; bu, **Save & Apply** tıkladığınızda değişikliklerin OpenWrt yapılandırma sistemine kaydedildiği anlamına gelir.

### Özet Kartları

Üstteki iki kart şunları gösterir:

- **Total Rules** -- Yapılandırmadaki kural bölümlerinin sayısı.
- **Active Rules** -- Etkin bayrağı ayarlanmış kuralların sayısı.

### Yeni Kural Ekleme

1. Kurallar tablosunun altına kaydırın ve **Add** düğmesine tıklayın.
2. Aşağıda açıklanan alanları doldurun.
3. Kuralı kaydetmek için **Save & Apply** tıklayın.

### Kural Alanları

| Alan               | Açıklama                                                                                                           |
|:-------------------|:-------------------------------------------------------------------------------------------------------------------|
| Enabled            | Açma/kapama onay kutusu. Devre dışı kurallar yapılandırmada kalır ancak yönlendirme tablosuna uygulanmaz.          |
| Rule Name          | Kural için benzersiz tanımlayıcı. Yalnızca harf, rakam, tire ve alt çizgi kullanılabilir. En fazla 32 karakter.    |
| Rule Type          | Hedef tipini seçin. **ASN** belirtilen otonom sistemlerin duyurduğu IP öneklerine yönelik trafiği yönlendirir. **IP/CIDR** açıkça listelenen IP aralıklarına trafiği yönlendirir. |
| ASN                | Kural Tipi ASN olduğunda görünür. Virgül veya boşlukla ayrılmış bir veya daha fazla ASN numarası girin (örn. `13335, 32934`). |
| IP/CIDR            | Kural Tipi IP/CIDR olduğunda görünür. Virgül veya boşlukla ayrılmış bir veya daha fazla CIDR bloğu girin (örn. `10.0.0.0/8, 172.16.0.0/12`). Hem IPv4 hem IPv6 CIDR gösterimi kabul edilir. |
| Interface          | Eşleşen trafiğin yönlendirileceği giden ağ arayüzü. Açılır liste hem fiziksel cihazları hem mantıksal UCI arayüzlerini gösterir. |
| Priority           | Sayısal öncelik değeri (1--32000). Düşük değerler önce işlenir. Varsayılan 100'dür.                                |
| Fallback Interface | İsteğe bağlı. Birincil arayüz çökerse trafik otomatik olarak bu arayüze yönlendirilir. Yedeklemeyi devre dışı bırakmak için "-- None --" seçin. |
| Tags               | Organizasyon amaçlı isteğe bağlı virgülle ayrılmış etiketler (örn. `vpn, office, streaming`).                     |

### Kural Düzenleme

Tablodaki tüm alanlar doğrudan düzenlenebilir. Herhangi bir değeri değiştirin ve sayfanın altındaki **Save & Apply** düğmesine tıklayın.

Kural Tipi açılır listesini değiştirdiğinizde, koşullu alanların (ASN ve IP/CIDR) değiştiğini belirtmek için satır kısaca sarı renkte vurgulanır.

### Kural Kaldırma

Herhangi bir kural satırının sağ tarafındaki **Delete** düğmesine tıklayın. Kural kaldırılmadan önce bir onay iletişim kutusu görüntülenir.

### Sürükle-Bırak Sıralama

Kurallar, tablo içinde satırları sürükleyerek yeniden sıralanabilir. Herhangi bir satırı tutun ve başka bir satırın üstüne veya altına sürükleyin. Bıraktığınızda öncelikler 100'den başlayarak 10'ar artışlarla otomatik olarak yeniden hesaplanır ve hemen arka uca kaydedilir.

Sürükleme sırasında bırakma konumunu gösteren görsel göstergeler (üst veya alt kenarlık vurguları) görünür.

### Kural Kopyalama

Her kural satırının işlemler sütununda bir **Clone** düğmesi bulunur. Tıklayın ve kopya için bir ad girin. Yeni kural, kaynak kuralın tüm ayarlarını (tip, ASN/IP hedefleri, arayüz, öncelik, etiketler) devralır ve etkin bayrağı korunur. Kopyalanan kural sayfa yeniden yüklendikten sonra görünür.

### Toplu İşlemler

Aynı anda birden fazla kural üzerinde işlem yapmak için:

1. Kuralları seçmek için en soldaki sütundaki onay kutularını kullanın. Başlıktaki "tümünü seç" onay kutusu tüm satırları değiştirir.
2. Bir veya daha fazla kural seçildiğinde, seçili kural sayısını ve aşağıdaki düğmeleri gösteren bir toplu araç çubuğu görünür:

| Düğme           | İşlem                                                         |
|:----------------|:--------------------------------------------------------------|
| Enable          | Seçili tüm kurallarda etkin bayrağını ayarlar.                |
| Disable         | Seçili tüm kurallarda etkin bayrağını temizler.               |
| Delete          | Onay isteminden sonra seçili tüm kuralları kaldırır.          |
| Export Selected | Yalnızca seçili kuralları içeren bir JSON dosyası indirir.    |

### JSON Dışa Aktarma

İki dışa aktarma seçeneği mevcuttur:

- **Export JSON** düğmesi (üst araç çubuğu) -- Tüm kuralları `mergen-rules.json` dosyası olarak indirir.
- **Export Selected** düğmesi (toplu araç çubuğu) -- Yalnızca işaretli kuralları indirir.

Dışa aktarılan JSON formatı:

```json
{
  "rules": [
    {
      "name": "example-rule",
      "type": "asn",
      "asn": "13335",
      "via": "wan",
      "priority": 100,
      "enabled": true
    }
  ]
}
```

### Tümünü Uygula

Kurallar sayfasının üstündeki **Apply All** düğmesi, tüm kuralların yönlendirme tablosuna anında uygulanmasını tetikler; komut satırından `mergen apply` çalıştırmaya eşdeğerdir.

---

## 3. ASN Tarayıcı Sayfası

**Gezinme:** Services > Mergen > ASN Browser

ASN Tarayıcı, otonom sistem bilgilerini aramanızı, duyurulan önekleri incelemenizi, birden fazla ASN'yi yan yana karşılaştırmanızı ve tarayıcı sonuçlarından doğrudan yönlendirme kuralları oluşturmanızı sağlar.

### ASN Arama

1. Arama alanına bir ASN numarası girin (örn. `13335` veya `AS13335`). "AS" öneki otomatik olarak kaldırılır.
2. **Search** düğmesine tıklayın veya Enter tuşuna basın.
3. Üç veya daha fazla basamaklı sayısal ASN girişlerinde, 300 milisaniye hareketsizlikten sonra arama otomatik olarak başlatılır.

Sorgu işlenirken "Resolving..." göstergesi görünür. ASN bulunamazsa veya sağlayıcı başarısız olursa arama çubuğunun altında bir hata mesajı görüntülenir.

### ASN Ayrıntı Paneli

Başarılı bir aramadan sonra dört bilgi kartı görünür:

| Kart          | İçerik                                                 |
|:--------------|:-------------------------------------------------------|
| ASN           | "AS" önekli ASN numarası (örn. AS13335).               |
| Sağlayıcı    | Sorguyu çözümleyen veri sağlayıcısı.                   |
| IPv4 Önekleri | Bu ASN tarafından duyurulan IPv4 öneklerinin sayısı.   |
| IPv6 Önekleri | Bu ASN tarafından duyurulan IPv6 öneklerinin sayısı.   |

### Önek Tablosu

Kartların altında, duyurulan tüm önekleri üç sütunla listeleyen sayfalandırılmış bir tablo bulunur: sıra numarası, önek (CIDR gösteriminde) ve tip (IPv4 veya IPv6).

**Filtreleme:** Tablonun üstündeki radyo düğmelerini kullanarak Tümü, Yalnızca IPv4 veya Yalnızca IPv6 öneklerini gösterin.

**Sayfalandırma:** Tablo sayfa başına 50 önek gösterir. Gezinmek için Önceki/Sonraki düğmelerini ve sayfa göstergesini kullanın. Aralık göstergesi (örn. "1-50 / 328") mevcut konumunuzu gösterir.

### Hızlı Kural Ekleme

Tarayıcıdan ayrılmadan görüntülenen ASN için bir yönlendirme kuralı oluşturmak için:

1. "Rule Name" alanına bir kural adı girin. Varsayılan ad `asn-<numara>` olarak önerilir (örn. `asn-13335`).
2. Açılır listeden hedef arayüzü seçin.
3. **Add Rule** düğmesine tıklayın.

Kural, UCI yapılandırmasında öncelik 100 ve etkin durumda bir ASN tipi kural olarak anında oluşturulur. Bir başarı mesajı oluşturmayı onaylar.

### ASN Karşılaştırma

En fazla dört ASN'yi yan yana karşılaştırabilirsiniz:

1. İlk ASN'yi arayın ve karşılaştırma setine eklemek için **Compare** düğmesine tıklayın.
2. Başka bir ASN arayın ve tekrar **Compare** tıklayın.
3. Toplam dört ASN'ye kadar tekrarlayın.

Karşılaştırma paneli arama sonuçlarının altında görünür ve her ASN için sağlayıcısını, IPv4 sayısını ve IPv6 sayısını gösteren bir kart görüntüler. Her kartta karşılaştırmadan çıkarmak için bir kaldır düğmesi (X) bulunur.

Karşılaştırmada iki veya daha fazla ASN olduğunda, Mergen otomatik olarak **ortak önekleri** hesaplar -- karşılaştırılan tüm ASN'ler tarafından duyurulan IP aralıkları. Bunlar karşılaştırma kartlarının altında ayrı bir bölümde listelenir. Ortak önek yoksa panel bunu açıkça belirtir.

Karşılaştırma setini sıfırlamak için **Clear Comparison** düğmesine tıklayın.

---

## 4. Sağlayıcılar Sayfası

**Gezinme:** Services > Mergen > Providers

Sağlayıcılar sayfası, Mergen'in ASN numaralarını IP önek listelerine çözümlemek için kullandığı veri kaynaklarını yapılandırır. Ayrıca geri dönüş stratejisi ve önbellek ayarlarını yönetir.

### Sağlayıcı Tablosu

Sağlayıcı tablosu, her satırın yapılandırılmış bir veri sağlayıcısını temsil ettiği UCI'ye bağlı bir formdur. Mevcut sütunlar:

| Sütun        | Açıklama                                                                                     |
|:-------------|:---------------------------------------------------------------------------------------------|
| Enabled      | Sağlayıcıyı etkinleştirmek veya devre dışı bırakmak için açma/kapama onay kutusu.           |
| Priority     | Sayısal öncelik (düşük değerler önce denenir). Varsayılan 10'dur.                            |
| API URL      | Sağlayıcının API'si için HTTPS uç noktası. `https://` ile başlamalıdır. Diğer protokolleri kullanan sağlayıcılar için boş bırakın (örn. whois). |
| Timeout      | Yanıt için beklenecek maksimum saniye (1--120). Varsayılan 30'dur.                           |
| Rate Limit   | Dakikadaki maksimum istek sayısı. Sınırsız için 0 ayarlayın.                                |
| Whois Server | IRR/RADB tipi sağlayıcılar için whois sunucu adı (örn. `whois.radb.net`).                   |
| DB Path      | MaxMind gibi yerel veritabanı sağlayıcıları için veritabanı dosyasının dosya sistemi yolu.   |
| Test         | Sağlayıcıya özel test düğmesi (aşağıya bakın).                                              |

Yeni sağlayıcı oluşturmak için alttaki **Add** düğmesini, bir sağlayıcıyı kaldırmak için ilgili satırdaki **Delete** düğmesini kullanın.

Sağlayıcılar sıralanabilir; geri dönüş sırasını kontrol etmek için yeniden sıralayabilirsiniz.

Değişiklikleri kaydetmek için **Save & Apply** tıklayın.

### Genel Sağlayıcı Ayarları

Sağlayıcı tablosunun altında "General Provider Settings" bölümü iki seçenek içerir:

| Ayar              | Açıklama                                                                                          |
|:------------------|:--------------------------------------------------------------------------------------------------|
| Fallback Strategy | Birincil başarısız olduğunda sağlayıcıların nasıl sorgulanacağını kontrol eder. **Sequential**: her sağlayıcıyı öncelik sırasına göre dener. **Parallel**: tüm sağlayıcıları aynı anda sorgular ve ilk yanıtı kullanır. **Cache Only**: yalnızca yerel önbellekten sunar, sağlayıcılarla asla iletişim kurmaz. |
| Cache TTL         | Önbelleğe alınmış önek verisi için saniye cinsinden yaşam süresi. Varsayılan 86400'dür (24 saat). Bu süre geçtikten sonra veriler bir sonraki güncelleme döngüsünde sağlayıcılardan yeniden alınır. |

### Sağlayıcı Bakımı

Sayfanın alt bölümü bakım işlemleri sunar:

- **Test All Providers** -- Bilinen bir ASN'yi (AS13335/Cloudflare) her sağlayıcı üzerinden çözümleyerek tüm yapılandırılmış sağlayıcılara karşı doğrulama kontrolü çalıştırır. Sonuçlar düğmelerin altındaki günlük panelinde görünür.
- **Clear All Cache** -- Tüm önbelleğe alınmış önek verilerini siler. Önce bir onay iletişim kutusu görüntülenir. Temizlemeden sonra önekler bir sonraki güncellemede sağlayıcılardan yeniden alınır.

### Sağlayıcı Bazında Test

Sağlayıcı tablosundaki her satırda ayrı bir **Test** düğmesi bulunur. Tıklamak, bir ASN çözümlemesi deneyerek o sağlayıcıyı test eder. Düğme geçici olarak sonucu gösterecek şekilde değişir:

- **OK** (yeşil) -- Sağlayıcı başarıyla yanıt verdi ve önek verisi döndürdü.
- **FAIL** (kırmızı) -- Sağlayıcı geçerli veri döndürmedi.

Düğme 5 saniye sonra varsayılan durumuna geri döner.

---

## 5. Arayüzler Sayfası

**Gezinme:** Services > Mergen > Interfaces

Arayüzler sayfası, sistemdeki tüm ağ arayüzlerini Mergen yönlendirmesiyle ilişkileriyle birlikte gösterir.

### Arayüz Durumu Tablosu

| Sütun        | Açıklama                                                                                   |
|:-------------|:-------------------------------------------------------------------------------------------|
| Ad           | Arayüz adı. Fiziksel cihazlar sistem adlarını gösterir (örn. `eth0`, `wlan0`). Mantıksal UCI arayüzleri "(logical)" sonekiyle görünür. |
| Durum        | Renk kodlu rozet: **up** (yeşil), **down** (kırmızı) veya fiziksel durumu belirlenemeyen mantıksal arayüzler için **unknown** (gri). |
| IP Adresi    | Arayüze atanmış birincil IP adresi; yoksa tire işareti.                                    |
| Mergen Kuralları | Bu arayüz üzerinden trafik yönlendiren etkin Mergen kurallarının sayısı.               |
| İşlemler     | Bu arayüz için bağlantı testi panelini açan **Ping** düğmesi.                             |

### Bağlantı Testi (Ping)

Herhangi bir arayüz satırındaki **Ping** düğmesine tıklamak bir test paneli açar:

1. **Target** -- Ping atılacak bir IP adresi veya ana bilgisayar adı girin. Varsayılan `8.8.8.8`'dir.
2. **Count** -- Açılır listeden 3, 5 veya 10 ping paketi seçin.
3. Testi çalıştırmak için **Ping** düğmesine tıklayın.

Test, seçili arayüz üzerinden (`-I` bayrağı kullanarak) ICMP paketleri gönderir ve şunları görüntüler:

- Günlük panelinde ham ping çıktısı.
- Özet kartları: **Gönderilen** paketler, **Alınan** paketler, **Kayıp** yüzdesi ve milisaniye cinsinden **Ortalama Gecikme**.

Bu, kural atamadan önce bir WAN arayüzünün bağlantısını doğrulamak için kullanışlıdır.

---

## 6. Kayıtlar Sayfası

**Gezinme:** Services > Mergen > Logs

Kayıtlar sayfası, OpenWrt syslog'dan alınan Mergen sistem günlük girişlerinin canlı, filtrelenebilir bir görünümünü sunar.

### Filtre Çubuğu

Sayfanın üst kısmında filtre kontrolleri bulunur:

| Kontrol        | Seçenekler / Açıklama                                                            |
|:---------------|:---------------------------------------------------------------------------------|
| Level          | Minimum önem derecesine göre filtreleme açılır listesi: All Levels, Error, Warning, Info, Debug. Bir seviye seçmek o seviyeyi ve daha ciddi tüm seviyeleri gösterir (örn. "Warning" seçimi Warning ve Error girişlerini gösterir). |
| Filter Text    | Serbest metin arama alanı. Mesaj gövdesine karşı metin eşleştirmesiyle günlük girişlerini filtreler (büyük/küçük harf duyarsız). Filtre, yazmayı bıraktıktan 300 milisaniye sonra uygulanır. |
| Lines          | Görüntülenecek günlük girişi sayısı: 25, 50, 100 veya 200.                      |
| Auto-refresh   | Onay kutusu (varsayılan olarak etkin). Aktif olduğunda günlük görünümü her 5 saniyede yenilenir. |

### Günlük Görünümü

Her günlük girişi tek bir satırda şunları içerir:

- **Zaman Damgası** -- Syslog'dan tarih ve saat.
- **Seviye Rozeti** -- Renk kodlu: Error (kırmızı), Warning (sarı/kehribar), Info (yeşil), Debug (gri).
- **Mesaj** -- Günlük mesajı metni.

Günlük kapsayıcısı her yenilemeden sonra en son girişe otomatik olarak kaydırılır.

### İşlem Düğmeleri

| Düğme              | Açıklama                                                                             |
|:-------------------|:-------------------------------------------------------------------------------------|
| Refresh            | Geçerli filtre ayarlarıyla günlük yenilemesini elle tetikler.                        |
| Download Log       | En fazla 500 günlük girişini alır ve `mergen-logs-YYYY-MM-DD.log` adlı bir `.log` metin dosyası olarak indirir. Her satır zaman damgası, köşeli parantez içinde seviye ve mesajı içerir. |
| Diagnostics Bundle | Kapsamlı bir tanılama paketi oluşturur ve `.txt` dosyası olarak indirir. Paket şunları içerir: Mergen durumu, kural listesi, doğrulama çıktısı, `ip rule show`, `ip route show table 100`, `nft list sets` ve en son 50 Mergen günlük girişi. |

Tanılama paketi, sorun bildirirken veya destek ararken özellikle kullanışlıdır.

---

## 7. Gelişmiş Ayarlar Sayfası

**Gezinme:** Services > Mergen > Advanced

Gelişmiş sayfa, sekmeli bölümler halinde düzenlenmiş tüm genel Mergen ayarlarına erişim sağlar; altta bakım işlemleri bulunur.

### Ana Etkinleştirme

Ayarlar formunun en üstünde, **Enabled** onay kutusu Mergen sisteminin genel açık/kapalı durumunu kontrol eder.

### Yönlendirme Sekmesi

| Ayar                     | Açıklama                                                                        | Varsayılan  |
|:-------------------------|:--------------------------------------------------------------------------------|:------------|
| Routing Table Number     | Mergen'in kullandığı Linux yönlendirme tablosu numarası (1--252).               | 100         |
| ip rule Priority Start   | Mergen'in oluşturduğu `ip rule` girişleri için başlangıç öncelik numarası (1--32000). | 100         |
| Operating Mode           | **Standalone** (önerilen): Mergen yönlendirme tablolarını bağımsız olarak yönetir. **mwan3 Integration**: Mergen, mwan3 çoklu WAN yöneticisiyle birlikte çalışır. | Standalone  |

### Paket Motoru Sekmesi

| Ayar                   | Açıklama                                                                             | Varsayılan |
|:-----------------------|:-------------------------------------------------------------------------------------|:-----------|
| Packet Matching Engine | **nftables** (önerilen): Önek eşleştirmesi için nftables setleri kullanır. **ipset** (eski): Eski ipset çerçevesini kullanır. OpenWrt sürümünüze ve kurulu paketlere göre seçin. | nftables   |

### IPv6 Sekmesi

| Ayar            | Açıklama                                                                            | Varsayılan |
|:----------------|:------------------------------------------------------------------------------------|:-----------|
| Enable IPv6     | IPv6 önek çözümleme ve yönlendirmeyi etkinleştirir/devre dışı bırakır. Devre dışı olduğunda yalnızca IPv4 önekleri işlenir. | Kapalı     |
| IPv6 Table Mode | Yalnızca IPv6 etkin olduğunda görünür. **Shared table with IPv4**: IPv6 rotaları IPv4 ile aynı yönlendirme tablosuna gider. **Separate IPv6 table**: IPv6 rotaları ayrı bir tablo numarası kullanır. | Shared     |

### Performans Sekmesi

| Ayar                                | Açıklama                                                                 | Varsayılan |
|:------------------------------------|:-------------------------------------------------------------------------|:-----------|
| Max Prefix Limit (per rule)         | Kural başına izin verilen maksimum önek sayısı. Aşırı duyuru yapan tek bir ASN'nin kaynakları tüketmesini önler. | 10000      |
| Total Prefix Limit (all rules)      | Tüm kurallar genelinde toplam maksimum önek sayısı.                      | 50000      |
| Update Interval (seconds)           | Önek verisinin sağlayıcılardan ne sıklıkla otomatik yenileneceği.       | 86400      |
| API Timeout (seconds)               | Sağlayıcı API yanıtı için maksimum bekleme süresi (1--120).             | 30         |
| Parallel Query Limit                | Önek çözümleme sırasında eşzamanlı sağlayıcı sorgu sayısı (1--10).      | 2          |

### Güvenlik Sekmesi

| Ayar                              | Açıklama                                                                         | Varsayılan |
|:----------------------------------|:---------------------------------------------------------------------------------|:-----------|
| Rollback Watchdog Timeout         | Yeni rotaları uyguladıktan sonra onaylamadan önce beklenecek saniye. Bu süre zarfında ping hedefine bağlantı kesilirse rotalar otomatik olarak geri alınır (10--600). | 60         |
| Safe Mode Ping Target             | Rota değişikliklerinden sonra bağlantıyı doğrulamak için nöbetçinin ping attığı IP adresi veya ana bilgisayar adı. | 8.8.8.8    |

### Günlükleme Sekmesi

| Ayar      | Açıklama                                                     | Varsayılan |
|:----------|:-------------------------------------------------------------|:-----------|
| Log Level | Syslog'a yazılan minimum günlük ciddiyeti: Debug, Info, Warning veya Error. | Info       |

### Bakım Bölümü

Sekmeli ayarların altında bakım bölümü aşağıdaki işlemleri sunar:

#### Tüm Rotaları Temizle

Mergen tarafından oluşturulan tüm rotaları ve nftables/ipset setlerini sistemden kaldırır. Tüm rotaların kaldırılacağı konusunda bir onay iletişim kutusu uyarır. Bu, kuralları yapılandırmadan silmez; rotalar Genel Bakış veya Kurallar sayfasında **Apply All** tıklayarak yeniden oluşturulabilir.

#### Yapılandırma Yedekleme

LuCI yedekleme mekanizması aracılığıyla mevcut `/etc/config/mergen` UCI yapılandırma dosyasını indirir. Yapılandırmanızı daha sonra geri yüklemek için bu dosyayı saklayın.

#### Yapılandırma Doğrulama

Mevcut yapılandırmanın bütünlüğünü doğrulamak ve tüm sağlayıcılara bağlantıyı test etmek için `mergen validate --check-providers` komutunu çalıştırır. Sonuçlar düğmelerin altındaki günlük panelinde görünür.

#### Fabrika Ayarlarına Sıfırlama

Tüm Mergen ayarlarını varsayılan değerlerine sıfırlar. Bu işlem:

- Yapılandırılmış tüm kuralları siler.
- Yapılandırılmış tüm sağlayıcıları siler.
- Her genel ayarı varsayılan değerine sıfırlar.
- Tüm aktif rotaları temizler.

Sıfırlama işlemine başlamadan önce iki ardışık onay iletişim kutusu kabul edilmelidir. Tamamlandıktan sonra sayfa otomatik olarak yeniden yüklenir.

#### Yapılandırma Geri Yükleme

Daha önce yedeklenmiş bir yapılandırmayı geri yüklemek için:

1. Dosya girişine tıklayın ve Mergen UCI yapılandırması içeren bir `.conf` veya `.txt` dosyası seçin.
2. Dosya seçildikten sonra **Restore Config** düğmesi aktif hale gelir.
3. **Restore Config** tıklayın ve değiştirmeyi onaylayın.

Yüklenen içerik, `config global` bölümü içerdiğinden emin olmak için doğrulanır. Başarılı olduğunda mevcut yapılandırma dosyası üzerine yazılır ve sayfa yeniden yüklenir.

#### Sürüm Bilgisi

Sayfanın alt kısmında üç sürüm değeri görüntülenir:

| Öğe            | Açıklama                                                      |
|:---------------|:--------------------------------------------------------------|
| Mergen CLI     | `mergen` komut satırı aracının sürümü.                        |
| LuCI App       | `luci-app-mergen` paketinin kurulu sürümü.                    |
| Config Version | Dahili yapılandırma şema sürüm numarası.                     |
