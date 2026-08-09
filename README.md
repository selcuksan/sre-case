# Case

Kubernetes üzerinde çalışan bir Java servisinin yük altında HPA ile ölçeklenmesi, OpenTelemetry ile izlenmesi ve bu ölçekleme davranışının Grafana üzerinden gösterilmesi.

## Ön koşullar

| Araçlar | Not |
|---|---|
| Docker | kind için gerekli |
| kind | Local Kubernetes cluster için gerekli |
| kubectl | Kubernetes API erişimi için gerekli |
| helm | metrics-server, grafana vb. kurulumu için gerekli |

## Adım 1 — Cluster

```bash
./scripts/cluster.sh up      # cluster + metrics-server kurar
./scripts/cluster.sh status  # node'lar ve anlık CPU/RAM
./scripts/cluster.sh down    # cluster'ı siler
```

`up` idempotent: cluster zaten varsa yeniden oluşturmaz, metrics-server zaten kuruluysa yeniden
kurmaz. Tekrar çalıştırmak sadece durum doğrulaması yapar.

### Kararlar ve gerekçeleri

| Karar | Gerekçe |
|---|---|
| GKE yerine **kind** | Case'in ölçtüğü şey (HPA + metrik + dashboard) ortamdan bağımsız. kind aynı davranışı bulut maliyeti ve kota beklemesi olmadan, tekrar üretilebilir şekilde verir. GKE farkları aşağıda. |
| **1 control-plane + 2 worker** | Sabit boyutlu node pool isteri için yeterli. |
| **Bash + YAML, Terraform değil** | Terraform’un resmi bir kind provider’ı yok. Community provider’lar var ama bu case için gereksiz; bash işimizi görüyor |
| **Kubernetes v1.32.0** | Versiyon sabit; aynı repo herkeste aynı versiyonu kuracaktır. |
| **metrics-server kurulumu** | Vanilla Kubernetes’te metrics-server built-in gelmez; HPA da onsuz çalışmaz. |
| **NodePort 30300 / 30080 host'a maplendi** | Grafana ve yük testi host'tan erişecek. Port mapping sonradan eklenemez (cluster'ı silip kurmak gerekir), o yüzden baştan konuldu. |

### Kapasite

Docker'a ayrılan kaynak: **10 CPU / 15.6 GB**. Ölçekleme davranışını node kapasitesi değil, HPA kararı belirleyecek.

### GKE olsaydı ne değişirdi?

Cluster'ı Terraform ile GKE **Standard** olarak kurardık; bu case için Standard daha mantıklı çünkü biz öncelikli olarak pod ölçeklenmesini görmek istiyoruz. 
Node'lar Docker container'ı yerine sabit sayıda gerçek VM olur, metrics-server hazır gelir ve servise NodePort yerine LoadBalancer üzerinden erişilirdi.

HPA, metrikler, dashboard iki ortamda da birebir aynı olacağı için değişen sadece altyapının nasıl sağlandığı olur.

## Adım 2 — Uygulama

Java 21 + Spring Boot 4.1.0. İskelet sıfırdan yazılmadı.

```bash
curl -s https://start.spring.io/starter.zip \
  -d type=maven-project -d language=java \
  -d bootVersion=4.1.0 -d javaVersion=21 \
  -d groupId=com.example -d artifactId=sre-case-app \
  -d packageName=com.example.app -d dependencies=web \
  -o /tmp/app.zip && unzip -q /tmp/app.zip -d app/
```

Üstüne tek bir dosya yazıldı: [WorkController.java](app/src/main/java/com/example/app/WorkController.java)

```bash
./scripts/build.sh        # image build + kind cluster'ına yükle
./scripts/build.sh push   # ayrıca Docker Hub'a push (docker login gerekir)
```

Image: `selcuksan/sre-case-app:x.y.z`

### Endpoint'ler

| Endpoint | Ne yapar |
|---|---|
| `GET /health` | `{"status":"UP"}` döner. Probe'lar buraya bakar. |
| `GET /work?n=...` | `n` kez üst üste SHA-256 hesaplar, `{"n","ms","hash"}` döner. Harcanan CPU `n` ile doğru orantılı. |

### İşi ölçtük

`n`, isteğe verdiğimiz "kaç kere SHA-256 hesaplayacağı" sayısıdır. Yükü bu sayıyla ayarlıyoruz. 1 CPU'lu container'da ölçtüğümüz cevap süreleri:

| n (istek başına iş) | cevap süresi |
|---|---|
| 100.000 | 13 ms |
| 200.000 | 25 ms |
| 400.000 | 51 ms |
| 800.000 | 101 ms |

İş tamamen hesaplama, arada disk veya ağ beklemesi yok. O yüzden geçen süre doğrudan yakılan CPU süresine eşit: 25 ms süren istek 25 ms CPU yemiş demek.

`n` iki katına çıkınca süre de tam iki katına çıkıyor, yani ilişki doğrusal. Bunu ölçekleyince
**n=8.000.000 bir CPU'yu tam bir saniye meşgul ediyor.**

Bu ölçüm yük testinde replica hedefini belirleyecek. Pod'a 1 CPU vereceğiz. `n=200.000`'lik bir
istek 25 ms CPU yiyorsa, bir pod saniyede 40 istek kaldırır (1000 ms ÷ 25 ms). Saniyede 400 istek gönderirsek HPA'nın 10 pod'a çıkması gerekir. Yani hedef replica sayısını bu hesapla seçiyoruz.

### JVM ve container limitleri

JVM açılırken makinede kaç CPU ve ne kadar RAM olduğuna bakar, heap'ini (nesneler için ayırdığı bellek) ona göre boyutlandırır. Eski JVM'ler container içinde
çalışsa dahi makinenin tamamını görürdü. Örneğin pod'a 512 MB limit vermişiz, JVM host'un 15.6 GB'ını görüp kendine birkaç GB heap ayırmaya kalkar, limiti aşar, Kubernetes pod'u OOMKilled ile öldürürdü.

Java 10+ ile JVM container/cgroup limitlerini otomatik olarak algılasa da şu iki işlem önemli:

1. **Pod'a gerçekten `limits` vermek.** Limit yoksa okunacak bir cgroup limiti de olmaz, JVM yine host'un tamamını görür.
2. **Heap yüzdesi.** JVM varsayılanı limitin sadece %25'i. [Dockerfile](app/Dockerfile)'da `-XX:MaxRAMPercentage=75` ile %75'e çıkardık.

JVM gördüğü CPU sayısına göre kendi thread havuzlarını kurar. Host'un
10 CPU'sunu gören bir JVM, 1 CPU'luk container'da gereğinden fazla thread açar. CPU tüketimi
dalgalanır, HPA da yanlış karar verir. 

Uygulama açılırken JVM'in container içinden gördüğü değerleri şu şekilde log'a
basması bekleniyor:

```
JVM container limits: availableProcessors=1, maxMemory=371MB, java=21.0.11
```

### Docker Hub

GCP yerine kind kullandığımız için Docker Hub'a push ediyoruz.

## Adım 3 — Ölçekleme

```bash
kubectl apply -f k8s/
```

[deployment.yaml](k8s/deployment.yaml), [service.yaml](k8s/service.yaml),
[hpa.yaml](k8s/hpa.yaml).

### Kararlar ve gerekçeleri

| Karar | Gerekçe |
|---|---|
| **requests = limits = 500m CPU / 512Mi** | İkisi eşit olunca pod Guaranteed QoS oluyor, HPA'nın gördüğü kullanım oranı da %100'ü aşamıyor. Ayrıca CPU limiti olmasaydı JVM host'un 10 CPU'sunu görürdü; Adım 2'deki `availableProcessors=1` kanıtı ancak limit varken geçerli. |
| **minReplicas 1, maxReplicas 10** | 10 × 500m = 5 CPU, host'un yarısı. |
| **Hedef CPU %50** | 500m'in yarısı, yani 250m. 60 saniyede gelen 10 kat trafiğe yetişmek için pay bırakmak gerekiyor; %80 hedefleseydik HPA geç kalırdı. |
| **scaleUp bekleme süresi 0** | Spike'ta beklemeden büyüsün. |
| **scaleDown bekleme süresi 120 sn** | Varsayılan 300 sn. 120'ye çektik ki çıkış ve iniş tek grafikte görünsün. |
| **Probe timeout'ları gevşetildi** | Varsayılan 1 saniye. Yük altında `/health` biraz gecikiyor. |

### İlk denemede ne oldu

İlk yük testinde ölçekleme hiç çalışmadı, tersine pod öldü. Sırasıyla:

1. Tek pod'a, kapasitesinin 10 katı istek bir anda gitti
2. İstekler sınırsız birikti, `/health` de bu kuyruğun arkasında kaldı
3. Readiness probe düştü, pod Service'ten çıktı
4. Liveness probe da düştü, kubelet pod'u öldürdü (4 restart)
5. Tek pod unready olunca HPA metrik göremedi: `cpu: <unknown>` → **hiç ölçeklenemedi**

**HPA'nın çalışması için pod'un ready kalması şart.** Yük altında sağlık kontrolünü kaybeden bir servis ölçeklenemez.

### Test ve sonuç

[loadtest/spike.js](loadtest/spike.js) — normal trafik, 60 saniyede
10 kat, sonra normale dönüş.

```bash
k6 run loadtest/spike.js
```

Kullanıcı sayısıyla pod sayısı arasındaki bağ: 20 kullanıcı 1 pod'u %50 dolduruyor, 10 katı olan
200 kullanıcı da 10 pod eder. Ölçüm sonucu:

| | |
|---|---|
| Replica seyri | 1 → 2 → 4 → **7**, yük bitince 7 → 5 → 3 → 2 → 1 |
| Toplam istek | 10.863 |
| Hata oranı | **%0** |
| Gecikme (p95) | 5,6 sn |
| Pending pod | **0** — bütün replica'lar Running/Ready |
| Node dağılımı | Pod'lar iki worker'a da yerleşti |

Ölçekleme hem yukarı hem aşağı çalışıyor ve hiçbir pod Pending'de kalmıyor.

Tepe noktada 10 değil 7 pod'a çıkıldı. Sebebi HPA değil, yük modeli: k6'nın sanal kullanıcıları
cevabı beklemeden yeni istek göndermiyor. Servis yavaşlayınca gönderilen istek sayısı da düşüyor,
dolayısıyla CPU talebi 7 pod seviyesinde dengeye geliyor. 10 pod'u görmek için kullanıcı sayısını
artırmak yeterli.


