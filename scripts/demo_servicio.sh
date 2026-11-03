#!/usr/bin/env bash
# Prueba los endpoints del servicio a través del balanceador (para el video).
#   ./scripts/demo_servicio.sh
set -u
cd "$(dirname "$0")/.."
APP=$(terraform -chdir=terraform output -raw app_url)
echo "Servicio: $APP"

for paso in "GET /health" "GET /status" "POST /api/visits" "GET /api/visits"; do
  metodo=${paso%% *}
  ruta=${paso#* }
  echo
  echo ">>> curl -X $metodo $APP$ruta"
  respuesta=$(curl -s -X "$metodo" "$APP$ruta")
  echo "$respuesta" | python -m json.tool 2>/dev/null || echo "$respuesta"
done
