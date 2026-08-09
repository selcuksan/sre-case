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

Bu ölçüm yük testinde replica hedefini belirlemek için kullanıldı: "kaç istek kaç CPU eder"
sorusunu tahminle değil bu oranla cevapladık. Ayrıntısı Adım 3'te.

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
| **Hedef CPU %20** | 500m'in %20'si, yani 100m. Düşük tuttuk: 60 saniyede 10 kat trafik alan bir serviste HPA'yı erken tetiklemek istiyoruz. Pod'lar dolmadan ölçeklenmeye başlıyoruz — kaynak karşılığında tepki süresi satın alıyoruz. Yüksek bir hedefte (%80 gibi) HPA geç kalır, istekler kuyruklanır. |
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

### Yük modeli: açık çevrim

[loadtest/spike.js](loadtest/spike.js) — baseline, 60 saniyede 10 kat artış, plato, düşüş.

```bash
k6 run loadtest/spike.js
```

k6'da iki model var ve seçim sonucu değiştiriyor:

| Model | Ne yapar | Gerçekçi mi |
|---|---|---|
| Kapalı çevrim (`ramping-vus`) | Sabit sayıda kullanıcı, her biri cevabı bekleyip yeni istek atar | Hayır. Servis yavaşlayınca yük de kendiliğinden azalır. |
| **Açık çevrim (`ramping-arrival-rate`)** | Saniyede sabit sayıda istek, servisin hızından bağımsız | **Evet.** Kampanya SMS'i giden kullanıcılar senin p95'ine bakıp beklemez. |

Açık çevrimi seçtik. Bir de `thresholds` ekledik (`http_req_failed: rate<0.05`), böylece test
sadece yük üretmiyor, geçti/kaldı da diyor.

Kapalı çevrimi de denedik ve şu farkı gördük: pod eklendikçe sistem daha çok iş yapıyordu ama
gecikme düşmüyordu, çünkü kullanıcılar boşalan kapasiteyi anında dolduruyordu. Açık çevrimde istek
hızı sabit olduğu için pod eklendikçe kuyruk gerçekten eriyor.

### Ölçüm sonucu

| | |
|---|---|
| Replica seyri | 1 → 3 → **10**, yük bitince 10 → 2 → 1 |
| 1'den 10'a çıkış süresi | ~2 dakika |
| Toplam istek | 8.519 |
| Hata oranı | **%0** |
| Gecikme: medyan / p95 | 29 ms / **217 ms** |
| Pending pod | **0** — bütün replica'lar Running/Ready |

Gecikme eğrisi hikâyeyi anlatıyor: pod'lar açılırken 300 ms'ye çıktı, 10 pod hazır olunca yük hâlâ
devam ederken 50 ms'ye indi.

### En önemli bulgu: pod açmak yetmiyor, trafiğin de taşınması gerekiyor

İlk açık çevrim testinde tuhaf bir sonuç çıktı. HPA 10 pod açtı, hepsi Ready oldu, ama **gecikme
düzelmedi** — p95 plato boyunca 4,8 saniyede kaldı. Oysa toplam yük saniyede 36 istekti; 10 pod'un
bunu rahat karşılaması gerekirdi.

Dashboard'da pod başına dağılıma bakınca sebep çıktı:

```
pod       CPU     istek/sn
b2gjj    497m      11,6      <- limitte, tıkalı
dq8p7    105m       6,8
7nx4v     99m       3,4
...
b9kx4      0m       0,0      <- hiç istek almamış
jq46j      0m       0,0
px7q6      0m       0,0
```

10 pod'dan üçü hiç istek almıyordu, biri tek başına limitine dayanmıştı. p95'teki 4,8 saniye
tamamen o tıkalı pod'un kuyruğuydu.

**Sebep:** k6 HTTP bağlantılarını yeniden kullanıyor (keep-alive). Kubernetes Service ise L4
seviyesinde çalışıyor ve dağıtımı **bağlantı bazında** yapıyor, istek bazında değil. Bağlantı
kurulurken bir pod seçiliyor ve o bağlantıdan gelen bütün istekler ömür boyu o pod'a gidiyor.
Test başlarken tek pod vardı, bütün bağlantılar ona kuruldu; HPA 9 pod daha açtı ama mevcut
bağlantılar taşınmadı.

Doğrulamak için `noConnectionReuse: true` ile tekrar çalıştırdık:

| | keep-alive açık | keep-alive kapalı |
|---|---|---|
| p95 gecikme | 4.590 ms | **217 ms** |
| Medyan | 82 ms | 29 ms |
| En kötü istek | 8,5 sn | 2,65 sn |
| Pod başına dağılım | 11,6 / 6,8 / ... / 0 / 0 / 0 | 0,7 / 0,7 / 0,6 / 0,6 / 0,3 ... |

21 kat fark. Ölçekleme baştan beri çalışıyordu; çalışmayan şey yük dağıtımıydı.

**Prod'da çözüm `noConnectionReuse` değildir** — o sadece bir test aracı, her istek için yeniden
bağlantı kurmak gecikmeyi ve CPU'yu artırır. Yapılması gereken:

| Katman | Yapılacak |
|---|---|
| Birincil | Servisin önüne istek bazında dağıtım yapan bir L7 katmanı: Ingress controller (nginx, Envoy) veya service mesh. Yeni pod anında pay alır. |
| Destekleyici | Sunucu tarafında bağlantı ömrünü sınırlamak (`max connection age`). Uzun ömürlü bağlantılar periyodik kopar ve yeniden dağılır. gRPC gibi tek uzun bağlantı kullanan protokollerde bu şart. |
| İzleme | Pod başına istek/CPU dağılımını dashboard'da tutmak. Biz bunu ancak arayarak bulduk; sürekli görünür olsaydı hemen fark edilirdi. |

### 10 replica'ya ulaşmak için ne gerekti

İlk denemelerde HPA 4-7 pod arasında takılıyordu. Kullanıcı sayısını artırarak çözmeye çalıştım,
işe yaramadı: kapalı çevrim modelde kullanıcı arttıkça gecikme de arttığı için saniyedeki istek
sayısı neredeyse sabit kalıyordu. 100 → 200 → 250 kullanıcı denemeleri 4 → 7 → 5 → 6 pod verdi;
yakınsama değil salınımdı.

Doğru kol HPA'nın kendi formülüydü:

```
istenen pod = toplam CPU tüketimi / (pod request x HPA hedefi)
```

Yükle oynamak payı çok az değiştiriyordu. Paydayı değiştirdik: HPA hedefini %50'den %20'ye çektik.

Arada pod'u 200m CPU'ya küçültmeyi de denedik; pod'lar Ready kalamadı, geri alındı.

## Adım 4 — Observability (OpenTelemetry)

```bash
./scripts/monitoring.sh up     # Prometheus + Grafana + Tempo + OTel Collector
./scripts/monitoring.sh down
```

Grafana: http://localhost:30300 (admin / admin)

### Akış

```
Uygulama (OTel Java agent)
   |
   +-- trace + metrik --OTLP push--> OTel Collector
                                          |
                                          +-- trace --OTLP push--> Tempo
                                          |
                                          +-- metrik: :8889/metrics
                                                          ^
                                                          | scrape (pull)
                                                     Prometheus
                                                          |
                                                       Grafana
```

Metrik yolu **pull**: Collector metrikleri kendi portunda yayınlıyor, Prometheus onları scrape
ediyor. Prometheus'un doğal çalışma şekli bu. Alternatifi olan remote write ile Collector doğrudan
Prometheus'a yazabilirdi ama remote write'ın asıl amacı veriyi uzun süreli depoya (Thanos, Mimir)
göndermek; tek bir Prometheus'a push için kullanmak aracı amacı dışında kullanmak olurdu.

Trace yolu **push** olarak kalıyor, çünkü Tempo'da scrape diye bir karşılık yok. Trace zaten olay
bazlı bir veri, üretildiği anda gönderilmesi gerekiyor.

### Kararlar ve gerekçeleri

| Karar | Gerekçe |
|---|---|
| **OTel Java agent (`-javaagent`)** | Kod değişikliği yok. HTTP istekleri, JVM metrikleri ve trace'ler kendiliğinden geliyor. Sürüm [Dockerfile](app/Dockerfile)'da sabitlendi (2.30.0). |
| **Collector var** | Zorunlu değildi, tercih. İki faydası: Kubernetes özniteliklerini (`k8s.pod.name` vb.) Collector ekliyor, uygulama kendi pod'unun adını bilmek zorunda kalmıyor. Ve uygulama tek adres biliyor — yarın Tempo'yu değiştirsek uygulamayı yeniden deploy etmeye gerek kalmıyor. |
| **Alloy yerine OTel Collector** | İkisi de aynı işi yapar. Collector'ün config'i düz YAML, Alloy'unki kendi dili. Ayrıca case'in dili OpenTelemetry; satıcı bağımsız olanı seçmek açıklamayı kolaylaştırıyor. |
| **Tempo tek binary** | Dağıtık kurulum (tempo-distributed) bu ölçek için gereksiz. |
| **Log toplamıyoruz** | Case istemiyor. `OTEL_LOGS_EXPORTER=none`. |
| **Gereksiz bileşenler kapalı** | kube-prometheus-stack varsayılanıyla kurulsa Alertmanager, node-exporter, ~100 alarm kuralı ve ~30 dashboard geliyordu. Hiçbirini kullanmıyoruz, kapattık. Açık kalanlar: Prometheus, Grafana, kube-state-metrics. |
| **kube-state-metrics açık** | HPA'nın replica sayısını Grafana'da çizebilmemiz onun metriklerine bağlı. |

### Neden `resource_to_telemetry_conversion`

Collector metrikleri yayınlarken Kubernetes özniteliklerini varsayılan olarak ayrı bir
`target_info` metriğine koyuyor, metriğin kendi etiketlerine değil. Bu haliyle Grafana'da pod
bazında kırılım yapılamıyor. [values-otel-collector.yaml](monitoring/values-otel-collector.yaml)'da
bu ayarı açtık, öznitelikler metrik etiketi haline geldi.

### Doğrulama

`service.name` ve Kubernetes öznitelikleri her iki sinyalde de geliyor.

Metrik tarafı (Prometheus, `jvm_cpu_count` etiketleri):

```
service_name        = sre-case-app
k8s_pod_name        = sre-case-app-7cb95f8c66-rh5tv
k8s_namespace_name  = default
k8s_node_name       = sre-case-worker
k8s_deployment_name = sre-case-app
```

Trace tarafı (Tempo'da mevcut etiketler):

```
service.name, k8s.pod.name, k8s.namespace.name, k8s.node.name,
k8s.deployment.name, k8s.container.name, k8s.replicaset.name
```

Agent uygulamanın açılışını 2,4 saniyeden 5,6 saniyeye çıkardı. Liveness probe'un 20 saniyelik
başlangıç gecikmesinin içinde kaldığı için bir değişiklik gerekmedi.

## Adım 5 — Grafana Dashboard

Dashboard tanımı: [grafana/dashboard.json](grafana/dashboard.json)

`./scripts/monitoring.sh up` bu dosyayı `grafana_dashboard` etiketli bir ConfigMap'e koyuyor;
Grafana'nın sidecar'ı otomatik alıyor. Arayüzden elle import yok, repo tek doğru kaynak.

Adres: http://localhost:30300/d/sre-case (admin / admin)

### Panel sırası neden böyle

Case dashboard'un "yük geldi → pod açıldı → latency düzeldi" hikâyesini tek bakışta anlatmasını
istiyor. Panelleri bu sebep-sonuç zincirine göre sıraladık, yukarıdan aşağı okununca hikâye
çıkıyor:

| Grup | Panel | Hikâyedeki yeri |
|---|---|---|
| **1. Trafik** | İstek hızı (RPS) | Yük geldi |
| | Gecikme p50/p95/p99 | Tek pod yetişemiyor, p95 sıçrıyor |
| | Hata oranı | Ölçekleme doğru çalışıyorsa sıfırda kalmalı |
| **2. Ölçekleme** | Replica: istenen vs hazır | Pod açıldı |
| | HPA CPU: mevcut vs hedef | HPA'nın kararının sebebi |
| **3. Container** | Pod başına CPU + limit | Podların gerçekten dolduğu an |
| **4. JVM** | Heap, GC süresi | Ölçeklemenin JVM tarafındaki etkisi |

Gecikme paneli en kritik olanı: p95'in önce sıçrayıp sonra düşmesi, "latency düzeldi" kısmının
kanıtı.

### İki panelde özellikle dikkat edilen nokta

**Replica paneli iki çizgi gösteriyor: HPA'nın istediği ve gerçekten Ready olan pod sayısı.**
Tek çizgi (sadece istenen) gösterseydik, podların Pending'de bekleyip beklemediği görünmezdi.
İki çizgi arasındaki boşluk pod'un açılıp henüz trafik almaya hazır olmadığı süre; hazır çizgisi
istenen çizgisini yakalıyorsa case'in "Pending'de bekleyen pod ölçeklenmiş sayılmaz" şartı
sağlanmış demektir.

**Container CPU panelinde limit ayrı bir kesikli çizgi olarak duruyor.** Kullanımın limite ne kadar
yaklaştığını göz kararı anlamak yerine doğrudan görüyoruz.

### Hata oranı panelinde bir ayrıntı

Hiç 5xx yokken bölme işlemi boş sonuç veriyor ve panel "No data" yazıyordu — bu, hata olmadığı
anlamına gelse de yanlış okunmaya açık. Sorguya `or vector(0)` ekledik, artık sıfır çiziyor.
"Hata yok" ile "veri yok" arasındaki fark bir dashboard'da önemli.


