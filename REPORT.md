# SRE Case — Rapor

Kubernetes üzerinde çalışan bir Java servisinin yük altında HPA ile ölçeklenmesi, OpenTelemetry ile
izlenmesi ve bu davranışın Grafana'da gösterilmesi.

GCP yerine local `kind` kullanıldı. Ölçekleme mantığı (HPA nesnesi, metrikler, dashboard) iki
ortamda birebir aynı; değişen sadece altyapının nasıl sağlandığı.

**Sonuç:** 60 saniyede 10 kat trafik altında servis 1'den 10 replica'ya çıktı, hiçbir pod Pending'de
kalmadı, 8.446 istekte hata alınmadı.

Kurulum ve ayrıntılı ölçümler: [README.md](README.md)

---

## 1. Mimari

```
                              HPA <-- metrics-server
                               |
  k6 --> NodePort --> Service --+--> [ Java pod x N ]
                                        |  OTel Java agent (-javaagent)
                                        |  OTLP (trace + metrik)
                                        v
                                  OTel Collector
                                   /          \
                          OTLP push          scrape (pull)
                             /                    \
                          Tempo               Prometheus <-- kube-state-metrics
                             \                    /                cadvisor
                              \                  /
                                    Grafana
```

Uygulama koduna dokunulmadı; enstrümantasyon `-javaagent` ile eklendi.

Collector zorunlu değildi ama iki iş yapıyor: Kubernetes özniteliklerini (`k8s.pod.name` vb.) o
ekliyor, ve uygulama tek adres bildiği için arka uç değişse yeniden deploy gerekmiyor.

Metrikler **scrape** ile alınıyor çünkü Prometheus pull tabanlı çalışır; remote write uzun süreli
depo (Thanos, Mimir) senaryosunun aracıdır. Trace tarafı push, çünkü Tempo'da scrape karşılığı yok.

---

## 2. Kararlar ve gerekçeleri

| Karar | Değer | Gerekçe |
|---|---|---|
| **Resource request / limit** | `cpu: 500m`, `memory: 512Mi` (request = limit) | İkisi eşit olunca pod Guaranteed QoS oluyor ve HPA'nın gördüğü kullanım oranı %100'ü aşamıyor. CPU limiti ayrıca zorunlu: limit olmasaydı JVM host'un 10 CPU'sunu görürdü. Log ile kanıtlandı: `availableProcessors=1, maxMemory=371MB`. |
| **JVM heap** | `-XX:MaxRAMPercentage=75` | JVM varsayılanı limitin %25'i — 512 MB'lık pod'da 128 MB heap demek. Sabit `-Xmx` yazılmadı; öyle olsa memory limiti her değiştiğinde image yeniden build edilirdi. |
| **HPA metriği** | CPU utilization | İş tamamen CPU-bound; istek başına 25 ms CPU ölçüldü. Bellek veya özel metrik bu iş yükünü temsil etmezdi. |
| **HPA hedefi** | %20 (= 100m) | 60 saniyede 10 kat trafikte pod'ların dolmasını beklemek geç kalmak demek. Düşük hedefle erken ölçekleniyoruz — fazladan pod maliyetine karşılık tepki süresi satın alıyoruz. |
| **scaleUp / scaleDown** | 0 sn / 120 sn | Büyürken atik, küçülürken temkinli. Yanlış pod açmanın maliyeti birkaç dakika kaynak; yanlış pod kapatmanın maliyeti trafik geri geldiğinde servisin çökmesi. |
| **Replica aralığı** | 1 – 10 | 10 × 500m = 5 CPU, host'un yarısı. Kapasite yettiği için hiçbir pod Pending'de kalmıyor. |
| **Readiness probe** | `/health`, 5 sn aralık, 3 sn timeout, 3 deneme | Varsayılan 1 sn timeout ile ölçüldü: aynı testte %11 hata ve pod restart'ı. Gevşetilince %0 hata. |
| **Liveness probe** | `/health`, 15 sn aralık, 5 sn timeout, 6 deneme | Liveness'ın işi takılmış process'i yakalamak, yavaş process'i değil. Sıkı ayarlanırsa yük altındaki sağlıklı pod'u öldürür ve ölçeklemeyi engeller. |
| **Node kapasitesi** | 1 control-plane + 2 worker, sabit | Case cluster autoscaler istemiyor. Ölçeklenen tek şey pod sayısı. kind node'ları host'un 10 CPU'sunu paylaşıyor; 5 CPU uygulamaya, kalanı monitoring ve yük üreticiye. |

---

## 3. Karşılaşılan problemler ve teşhis

**1. HPA hiç ölçeklenmedi.** İlk yük testinde replica sayısı 1'de kaldı, `kubectl get hpa` çıktısı
`cpu: <unknown>` gösterdi.

*Teşhis:* `kubectl describe pod` → liveness probe fail ve 4 restart. Tek pod'a kapasitesinin 10 katı
istek gitmiş, istekler sınırsız birikmiş, `/health` de bu kuyruğun arkasında kalmış. Pod unready
olunca metriği HPA'ya gitmemiş.

*Ders:* HPA'nın çalışması için pod'un ready kalması şart. Yük altında sağlık kontrolünü kaybeden
servis ölçeklenemez.

*Çözüm:* Probe timeout'ları gevşetildi + yük profili rampalı hale getirildi.

**2. 10 pod açıldı ama gecikme düzelmedi.** p99 plato boyunca 4,8 saniyede kaldı, oysa toplam yük
saniyede 36 istekti — 10 pod'un rahat karşılaması gerekirdi.

*Teşhis:* Pod bazında CPU ve istek sorgusu. Bir pod 497m (limitinde), üçü 0m — hiç istek almamış.

*Sebep:* k6 HTTP bağlantılarını yeniden kullanıyor (keep-alive). Kubernetes Service L4 seviyesinde
çalışıyor ve dağıtımı **bağlantı bazında** yapıyor, istek bazında değil. Test başlarken tek pod
vardı, bütün bağlantılar ona kuruldu; HPA 9 pod daha açtı ama mevcut bağlantılar taşınmadı.

*Kanıt:* `noConnectionReuse: true` ile tekrar çalıştırıldı → p95 **4.590 ms → 217 ms** (21 kat).

*Ders:* Ölçekleme çalışıyordu; çalışmayan şey yük dağıtımıydı.

**3. HPA 10 replica'ya çıkmıyordu.** 4-7 arasında salınıyordu.

*Teşhis:* Yük artırarak çözmeye çalışmak işe yaramadı (100 → 200 → 250 kullanıcı, sonuç 4 → 7 →
5 → 6). Kapalı çevrim yük modelinde kullanıcı arttıkça gecikme de arttığı için saniyedeki istek
sayısı sabit kalıyordu. HPA'nın formülü yazılınca doğru kol göründü:

```
istenen pod = toplam CPU tüketimi / (pod request x HPA hedefi)
```

*Çözüm:* Payı (yük) değil paydayı değiştirmek — HPA hedefi %50'den %20'ye çekildi.

---

## 4. Prod'a alacak olsaydım

| Değişiklik | Neden |
|---|---|
| Servisin önüne **L7 katmanı** (Ingress controller / service mesh) | 2. problemin kalıcı çözümü. L4 Service tek başına keep-alive'lı trafiği yeni pod'lara taşıyamıyor. Destekleyici olarak sunucu tarafında bağlantı ömrü sınırı (`max connection age`). |
| Kampanya öncesi **`minReplicas` yükseltmek** | HPA'nın tepki süresi fiziksel olarak 45-70 saniye (metrics-server 15 sn + HPA 15 sn + pod açılışı ~18 sn). Bu süre boyunca servis yüksek gecikmeyle çalışıyor. Çare HPA'yı hızlandırmak değil, spike'a hazır girmek. |
| **`scaleDown` penceresini 300 sn'ye** geri almak | Varsayılan değer. 120'ye çekilme sebebi çıkış ve inişin tek grafikte görünmesiydi — demo kararı. |
| **HPA hedefini SLO'dan türetmek** | %20 burada demo görünürlüğü için seçildi. Gerçek sistemde önce "p95 300 ms altında kalsın" denir, hedef oradan hesaplanır. |
| **Metrik aralığını 30-60 sn'ye** geri almak | Analiz için 10 saniyeye çekildi. Sürekli 10 saniye gereksiz metrik hacmi demek; olay incelemesinde geçici olarak düşürülür. |
| Pod başına **istek dağılımı panelini kalıcı izlemeye** almak | 2. problem ancak arayarak bulundu. Sürekli görünür olsa hemen fark edilirdi. |
| PodDisruptionBudget, ResourceQuota, ayrı namespace, NetworkPolicy | Bu case'de kapsam dışıydı. |
| Yük testini CI'a bağlamak | k6 `thresholds` zaten var, sürüm öncesi otomatik kapı olarak çalışabilir. |

---

## 5. Maliyet

| Kalem | Tutar |
|---|---|
| Bulut maliyeti | **0 USD** — her şey local `kind` üzerinde çalıştı |
| Donanım | Docker'a ayrılan 10 CPU / 15,6 GB; tepe kullanım ~7 CPU |
| Süre | ~6 saat |

**GKE'de yapılsaydı (yaklaşık):** 3 × `e2-standard-2` ≈ 0,20 USD/saat, LoadBalancer ≈ 0,025
USD/saat, Artifact Registry ihmal edilebilir. 6 saatlik çalışma için **~1,5 USD**; cluster sürekli
açık bırakılsaydı **ayda ~160 USD**. Fiyatlar bölgeye ve taahhüt indirimlerine göre değişir.

Asıl maliyet kalemi bulut değil, **mühendis saati** oldu: 6 saatin yaklaşık yarısı yük testi
çalıştırıp sonucunu beklemekle geçti. Prodüksiyonda bu süreyi kısaltmanın yolu testleri CI'a alıp
paralel çalıştırmak.
