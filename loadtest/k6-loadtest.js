// Prueba de carga contra el balanceador.
//
//   k6 run -e BASE_URL=http://<alb> -e AZS=us-east-1a,us-east-1b loadtest/k6-loadtest.js
//
// PERFIL=corta (por defecto, 2 minutos, hasta 100 usuarios) para el video.
// PERFIL=larga (7 minutos, hasta 150 usuarios) para la prueba previa que
// dispara el escalado automático y deja la evidencia en CloudWatch.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8080').replace(/\/$/, '');
const AZS = (__ENV.AZS || '').split(',').filter((z) => z);
const PERFIL = __ENV.PERFIL || 'corta';

// Un contador por zona: muestra cuántas solicitudes atendió cada zona.
const hitsPorZona = {};
for (const az of AZS) {
  hitsPorZona[az] = new Counter(`instance_hits_${az.replace(/-/g, '_')}`);
}

const perfiles = {
  corta: [
    { duration: '20s', target: 20 },
    { duration: '40s', target: 60 },
    { duration: '40s', target: 100 },
    { duration: '20s', target: 0 },
  ],
  larga: [
    { duration: '1m', target: 50 },
    { duration: '2m', target: 100 },
    { duration: '3m', target: 150 },
    { duration: '1m', target: 0 },
  ],
};

export const options = {
  stages: perfiles[PERFIL] || perfiles.corta,
  thresholds: {
    http_req_failed: ['rate<0.05'], // menos del 5 % de errores
    http_req_duration: ['p(95)<1500'], // p95 por debajo de 1,5 s
  },
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)'],
};

export default function () {
  const info = http.get(`${BASE_URL}/api/info`, { tags: { endpoint: 'info' } });
  check(info, { 'api/info responde 200': (r) => r.status === 200 });

  const res = http.get(`${BASE_URL}/api/stress?ms=50`, { tags: { endpoint: 'stress' } });
  const ok = check(res, { 'api/stress responde 200': (r) => r.status === 200 });
  if (ok) {
    try {
      const az = res.json('az');
      if (hitsPorZona[az]) hitsPorZona[az].add(1);
    } catch (e) {
      // respuesta no JSON: se ignora
    }
  }
  sleep(0.5);
}
