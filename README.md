# SRE Case — Yük Altında Otomatik Ölçeklenen Java Servisi

Kubernetes üzerinde HPA ile ölçeklenen bir Java servisi, OpenTelemetry ile gözlemlenebilirlik ve
ölçekleme davranışının Grafana'da kanıtlanması.

## Ön koşullar

| Araçlar | Not |
|---|---|
| Docker | kind için gerekli |
| kind | Local Kubernetes cluster için gerekli |
| kubectl | Kubernetes API erişimi için gerekli|
| helm | metrics-server, grafana vb. kurulumu için gerekli|

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


