# Case

Kubernetes üzerinde çalışan bir Java servisinin yük altında HPA ile ölçeklenmesi, OpenTelemetry ile izlenmesi ve bu ölçekleme davranışının Grafana üzerinden gösterilmesi.

Tasarım kararları, karşılaşılan problemler ve analiz: [REPORT.md](REPORT.md)

## Ön koşullar

| Araç | Not |
|---|---|
| Docker | kind için gerekli, çalışır durumda olmalı |
| kind | Local Kubernetes cluster |
| kubectl | Kubernetes API erişimi |
| helm | metrics-server, Prometheus, Grafana, Tempo, OTel Collector kurulumu |
| k6 | Yük testi |

## Sıfırdan çalıştırma

Sıra önemli: monitoring uygulamadan önce kurulmalı, yoksa uygulama açılışta OTel Collector'ü
bulamaz.

```bash
# 1. kind cluster + metrics-server                    (~2 dk)
./scripts/cluster.sh up
#    beklenen: 3 node Ready, "kubectl top nodes" veri döndürüyor

# 2. Prometheus, Grafana, Tempo, OTel Collector       (~4 dk)
./scripts/monitoring.sh up
#    beklenen: monitoring namespace'inde 6 pod Running

# 3. Uygulama image'ını build et ve cluster'a yükle   (~2 dk)
./scripts/build.sh
#    beklenen: selcuksan/sre-case-app üç node'a da yüklendi

# 4. Deployment + Service + HPA
kubectl apply -f k8s/
kubectl rollout status deploy/sre-case-app
curl localhost:30080/health          # {"status":"UP"}

# 5. Yük testi                                        (~6 dk)
k6 run loadtest/spike.js
```

Yük testi sırasında ayrı bir terminalde:

```bash
kubectl get hpa sre-case-app -w
kubectl get pods -l app=sre-case-app -w
```

**Grafana:** http://localhost:30300/d/sre-case — kullanıcı `admin`, şifre `admin`
(local demo kimlik bilgisi).

Dashboard'da göreceğin: istek hızı yükselir, gecikme önce sıçrar, HPA replica sayısını 1'den 10'a
çıkarır, gecikme yük hâlâ tepedeyken düşer, yük bitince replica sayısı 1'e iner.

## Diğer komutlar

```bash
./scripts/cluster.sh status    # node'lar ve anlık CPU/RAM
./scripts/build.sh push        # image'ı ayrıca Docker Hub'a push eder (docker login gerekir)
./scripts/monitoring.sh down   # monitoring yığınını siler
./scripts/cluster.sh down      # cluster'ı komple siler
```

`cluster.sh up` ve `monitoring.sh up` idempotent: kurulu olanı yeniden kurmaz, tekrar çalıştırmak
sadece durum doğrulaması yapar.

## Repo yapısı

| Yol | İçerik |
|---|---|
| [kind-config.yaml](kind-config.yaml) | Cluster topolojisi: 1 control-plane + 2 worker, NodePort eşlemeleri |
| [scripts/](scripts/) | `cluster.sh` (cluster + metrics-server), `monitoring.sh` (gözlemlenebilirlik yığını), `build.sh` (image) |
| [app/](app/) | Java 21 + Spring Boot servisi ve Dockerfile |
| [k8s/](k8s/) | Deployment, Service, HPA |
| [monitoring/](monitoring/) | Prometheus, Grafana, Tempo ve OTel Collector helm values dosyaları |
| [grafana/dashboard.json](grafana/dashboard.json) | Dashboard tanımı; `monitoring.sh up` bunu ConfigMap olarak yükler |
| [loadtest/spike.js](loadtest/spike.js) | k6 yük testi: baseline → 10 kat artış → plato → düşüş |

## Uygulama

İskelet Spring Initializr'dan üretildi:

```bash
curl -s https://start.spring.io/starter.zip \
  -d type=maven-project -d language=java \
  -d bootVersion=4.1.0 -d javaVersion=21 \
  -d groupId=com.example -d artifactId=sre-case-app \
  -d packageName=com.example.app -d dependencies=web \
  -o /tmp/app.zip && unzip -q /tmp/app.zip -d app/
```

Üstüne tek dosya yazıldı: [WorkController.java](app/src/main/java/com/example/app/WorkController.java)

| Endpoint | Ne yapar |
|---|---|
| `GET /health` | `{"status":"UP"}` döner. Probe'lar buraya bakar. |
| `GET /work?n=...` | `n` kez üst üste SHA-256 hesaplar. Harcanan CPU `n` ile doğru orantılı. Yük testinde `n=200000` kullanılıyor, bu 1 CPU'da yaklaşık 25 ms. |
