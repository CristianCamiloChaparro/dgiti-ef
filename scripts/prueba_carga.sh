#!/usr/bin/env bash
# Lanza la prueba de carga k6 contra el balanceador desplegado.
#   ./scripts/prueba_carga.sh          -> perfil corta (2 min, hasta 100 usuarios) para el video
#   ./scripts/prueba_carga.sh larga    -> perfil larga (7 min, hasta 150 usuarios) prueba previa
set -u
cd "$(dirname "$0")/.."
PERFIL="${1:-corta}"
APP=$(terraform -chdir=terraform output -raw app_url)
AZS=$(terraform -chdir=terraform output -raw availability_zones)
mkdir -p loadtest/results

echo "Prueba de carga ($PERFIL) contra $APP"
k6 run -e BASE_URL="$APP" -e AZS="$AZS" -e PERFIL="$PERFIL" \
  --summary-export="loadtest/results/summary-$PERFIL.json" \
  loadtest/k6-loadtest.js
