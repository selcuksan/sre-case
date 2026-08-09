import http from 'k6/http';

export const options = {
  // Her istek yeni baglanti kurar. Kubernetes Service L4 seviyesinde baglanti bazinda
  // dagitim yapiyor; keep-alive acikken HPA yeni pod acsa bile mevcut baglantilar eski
  // poda gitmeye devam ediyor ve yuk dagilmiyor. Prod'da cozum bu degil, servisin onune
  // istek bazinda dagitan bir L7 katmani (Ingress / service mesh / Gateway API) koymaktir.
  noConnectionReuse: true,

  scenarios: {
    spike: {
      // Acik cevrim: saniyede sabit istek. Gercek trafik boyle davranir, servis
      // yavasladi diye kullanicilar gelmeyi birakmaz.
      executor: 'ramping-arrival-rate',
      startRate: 4,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 600,
      stages: [
        { duration: '45s', target: 4 },    // baseline -> 1 pod
        { duration: '1m', target: 40 },    // ani artis: 60 saniyede 10 kat
        { duration: '150s', target: 40 },  // plato
        { duration: '30s', target: 4 },    // dusus
        { duration: '90s', target: 4 },    // scale-down gozlemi
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
  },
};

export default function () {
  http.get('http://localhost:30080/work?n=200000');
}
