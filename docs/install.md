# Mergen Kurulum Kılavuzu

[English](install.en.md)

Mergen, OpenWrt için ASN/IP tabanlı politika yönlendirme aracıdır. Hedef ASN
veya IP aralıklarına göre trafiği farklı WAN arayüzleri üzerinden
yönlendirmenizi sağlar.

---

## Gereksinimler

| Gereksinim       | Minimum                                       |
|------------------|-----------------------------------------------|
| OpenWrt sürümü   | 23.05 veya sonrası                            |
| Güvenlik duvarı  | nftables (varsayılan) veya iptables ile ipset |
| Disk alanı       | ~500 KB                                       |
| RAM              | 32 MB veya daha fazla                         |

Mergen hem nftables (OpenWrt 22.03+ ile varsayılan) hem de eski iptables/ipset
arka ucunu destekler. Uygun arka uç çalışma zamanında otomatik olarak algılanır.

---

## opkg ile Kurulum

Çoğu kullanıcı için önerilen yöntemdir.

```sh
opkg update
opkg install mergen luci-app-mergen
```

`luci-app-mergen` paketi isteğe bağlıdır ve LuCI üzerinden bir web arayüzü
sağlar. Mergen'i yalnızca komut satırı üzerinden yönetmeyi planlıyorsanız bu
paketi atlayabilirsiniz.

---

## Kaynaktan Manuel Kurulum

Paket akışında henüz kapsanmayan geliştirme derlemeleri veya mimariler için
Mergen'i OpenWrt derleme sistemi içerisinde derleyebilirsiniz.

1. Depoyu OpenWrt kaynak ağacınıza klonlayın:

   ```sh
   cd /path/to/openwrt
   git clone https://github.com/KilimcininKorOglu/luci-app-mergen.git package/mergen
   ```

2. Akış indeksini güncelleyin ve paketi seçin:

   ```sh
   make menuconfig   # Navigate to Network -> Routing and Redirection -> mergen
   ```

3. Paketi derleyin:

   ```sh
   make package/mergen/compile V=s
   ```

4. Oluşturulan `.ipk` dosyası `bin/packages/` altında bulunacaktır. Dosyayı
   yönlendiricinize aktarın ve elle kurun:

   ```sh
   opkg install /tmp/mergen_*.ipk
   ```

---

## Kurulum Sonrası Doğrulama

Kurulumdan sonra Mergen'in çalışır durumda olduğunu doğrulayın:

```sh
mergen version
```

Beklenen çıktı, kurulu sürüm numarası ve derleme bilgisini içerir.

```sh
mergen status
```

Bu komut mevcut yönlendirme politikası durumunu, aktif kuralları ve kullanılan
güvenlik duvarı arka ucunu görüntüler. Sağlıklı bir kurulum hatasız olarak
`status: running` rapor eder.

---

## Bağımlılıklar

Mergen, opkg ile kurulduğunda aşağıdaki bağımlılıkları otomatik olarak çeker:

| Bağımlılık | Amaç                                                          |
|------------|---------------------------------------------------------------|
| dnsmasq    | DNS tabanlı yönlendirme için gerekli (ipset/nftset entegre)  |
| nftables   | Küme tabanlı yönlendirme kuralları için varsayılan arka uç    |
| ipset      | iptables kullanıldığında alternatif arka uç (eski sistemler)  |

OpenWrt kurulumunuz varsayılan nftables arka ucunu kullanıyorsa ek bir
yapılandırma gerekmez. iptables tabanlı kurulumlar için `kmod-ipt-ipset` ve
`ipset` paketlerinin kurulu olduğundan emin olun.

> **Not:** Mergen çoğu durumda dnsmasq-full yerine dnsmasq gerektirir. Ancak
> gelişmiş DNS özelliklerine (DNSSEC, conntrack işaretleme) ihtiyacınız varsa
> bunun yerine `dnsmasq-full` kurun.

---

## Güncelleme

Mevcut bir kurulumu güncellemek için:

```sh
opkg update
opkg upgrade mergen
```

Yapılandırma geçişi otomatiktir. Mevcut yönlendirme politikalarınız, ASN
listeleri ve arayüz atamaları güncellemeler arasında korunur. Manuel müdahale
gerekmez.

Güncellemeden sonra yeni sürümü doğrulayın:

```sh
mergen version
mergen status
```

---

## Kaldırma

Mergen'i ve LuCI arayüzünü kaldırmak için:

```sh
opkg remove luci-app-mergen
opkg remove mergen
```

Bu işlem ikili dosyaları ve varsayılan yapılandırmayı kaldırır. `/etc/mergen/`
altındaki özel yapılandırma dosyaları opkg'nin conffile mekanizması tarafından
korunur. Yapılandırma dahil tam bir kaldırma için:

```sh
opkg remove mergen luci-app-mergen
rm -rf /etc/mergen/
```

Kaldırma işleminden sonra kalan yönlendirme kurallarını temizlemek için güvenlik
duvarını yeniden başlatın:

```sh
/etc/init.d/firewall restart
```
