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


