#!/usr/bin/env bash
# Despliegue gradual: reemplaza las instancias del Auto Scaling Group de una en
# una, esperando que la nueva quede sana en el balanceador antes de seguir.
# (AWS Academy bloquea autoscaling:StartInstanceRefresh, por eso se hace así.)
#   ./scripts/despliegue_gradual.sh [proyecto]
set -euo pipefail
PROJECT="${1:-dgiti-ef}"
ASG="$PROJECT-asg"

TG=$(aws elbv2 describe-target-groups --names "$PROJECT-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
DESIRED=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].DesiredCapacity' --output text)
VIEJAS=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text)
echo "ASG $ASG: capacidad $DESIRED. Instancias a reemplazar: $VIEJAS"

sanas() {
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query "TargetHealthDescriptions[?TargetHealth.State=='healthy'].Target.Id" --output text
}

for ID in $VIEJAS; do
  echo "== Reemplazando $ID"
  aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$ID" \
    --no-should-decrement-desired-capacity > /dev/null
  for i in $(seq 1 60); do
    S=$(sanas)
    n=$(echo "$S" | wc -w)
    if ! echo "$S" | grep -q "$ID" && [ "$n" -ge "$DESIRED" ]; then
      echo "   lista: $n instancias sanas ($S)"
      break
    fi
    if [ "$i" -eq 60 ]; then
      echo "estado=Failed"
      exit 1
    fi
    echo "   esperando a la instancia nueva... sanas=$n"
    sleep 15
  done
done
echo "estado=Successful"
