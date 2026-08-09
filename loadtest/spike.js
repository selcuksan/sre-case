import http from 'k6/http';
import { sleep } from 'k6';

export const options = {
  scenarios: {
    spike: {
      executor: 'ramping-vus',
      startVUs: 20,
      stages: [
        { duration: '45s', target: 20 },   // baseline: 20 kullanici -> 1 pod
        { duration: '1m', target: 200 },   // ani artis: 60 saniyede 10 kat
        { duration: '2m', target: 200 },   // plato
        { duration: '30s', target: 20 },   // dusus
        { duration: '90s', target: 20 },   // scale-down gozlemi
      ],
    },
  },
};

export default function () {
  http.get('http://localhost:30080/work?n=200000');
  sleep(1);
}
