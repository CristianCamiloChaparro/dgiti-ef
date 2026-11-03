#!/usr/bin/env bash
# Muestra qué instancia y zona atiende cada solicitud a través del ALB.
#   ./loadtest/check_balancer.sh <app_url> [numero_de_solicitudes]
set -u
URL="${1:?Uso: $0 <app_url> [numero_de_solicitudes]}"
URL="${URL%/}"
N="${2:-20}"

declare -A CUENTA
errores=0

for i in $(seq 1 "$N"); do
  body=$(curl -s -m 5 "$URL/api/info" || true)
  id=$(echo "$body" | sed -n 's/.*"instance_id": *"\([^"]*\)".*/\1/p')
  az=$(echo "$body" | sed -n 's/.*"az": *"\([^"]*\)".*/\1/p')
  if [ -n "$id" ]; then
    printf '%2d  %-22s %s\n' "$i" "$id" "$az"
    clave="$id ($az)"
    CUENTA["$clave"]=$(( ${CUENTA["$clave"]:-0} + 1 ))
  else
    printf '%2d  ERROR\n' "$i"
    errores=$((errores + 1))
  fi
done

echo "------ Resumen ------"
for clave in "${!CUENTA[@]}"; do
  echo "$clave: ${CUENTA[$clave]} solicitudes"
done
echo "Errores: $errores de $N"
