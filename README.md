# dgiti-ef · Evaluación final DGITI

Servicio web en AWS desplegado con Terraform, CI/CD con GitHub Actions, prueba de carga con k6 y monitoreo en CloudWatch.

![Arquitectura](docs/arquitectura-aws.png)

> Diagrama editable: `docs/arquitectura-aws.drawio` (ábrelo en https://app.diagrams.net). Usa los iconos oficiales de AWS.

## Arquitectura

| Capa | Recursos |
|---|---|
| Red | VPC `10.0.0.0/16`, 2 zonas (us-east-1a / us-east-1b), 2 subredes públicas (ALB, NAT), 2 privadas de app (EC2), 2 privadas de BD sin ruta a Internet, Internet Gateway, 1 NAT Gateway, VPC endpoint de S3 |
| Seguridad | `dgiti-ef-alb-sg` (80 desde Internet) → `dgiti-ef-app-sg` (8080 solo desde el ALB) → `dgiti-ef-db-sg` (3306 solo desde la app). EC2 sin IP pública, IMDSv2 obligatorio, RDS cifrado |
| Cómputo | Application Load Balancer + Auto Scaling Group `dgiti-ef-asg` (t3.micro, mín 2, máx 4, escala con CPU > 50 %) |
| Datos | RDS MySQL primaria (escrituras) + réplica de lectura en la otra zona (lecturas) |
| Almacenamiento | S3 `dgiti-ef-artifacts-<cuenta>`: código de la app y reportes del pipeline |
| Monitoreo | Dashboard de CloudWatch `dgiti-ef-dashboard` + alarma de CPU del escalado |

## Estructura

```
app/                      Servicio Flask (gunicorn :8080)
tests/unit/               15 pruebas unitarias (BD simulada)
tests/integration/        4 pruebas contra el balanceador real
terraform/                provider.tf, variables.tf, main.tf, outputs.tf,
                          terraform.tfvars.example, user_data.sh, tests/
.github/workflows/        ci-cd.yml (3 etapas)
loadtest/                 k6-loadtest.js, check_balancer.sh
scripts/                  demo_servicio.sh, prueba_carga.sh
docs/                     diagrama, guion del video, preparación
```

## Endpoints

| Método | Ruta | Qué hace |
|---|---|---|
| GET | `/` | Página que muestra la instancia y la zona que respondió |
| GET | `/health` | Validación para el balanceador |
| GET | `/status` | Conexión con la BD primaria y la réplica |
| GET | `/api/info` | Datos de la instancia |
| POST | `/api/visits` | Escribe una visita en la primaria |
| GET | `/api/visits` | Lee el total desde la réplica |
| GET | `/api/stress?ms=50` | Consume CPU (prueba de carga) |

## Desplegar (en Git Bash)

```bash
# 1. Credenciales de AWS Academy en ~/.aws/credentials y comprobar
aws sts get-caller-identity

# 2. Terraform
cd terraform
cp terraform.tfvars.example terraform.tfvars   # editar db_password
terraform init
terraform plan
terraform apply          # ~20-25 min (RDS + réplica)
terraform output

# 3. Probar el servicio (desde la raíz del repositorio)
cd ..
./scripts/demo_servicio.sh

# 4. Prueba de carga
./scripts/prueba_carga.sh           # 2 min
./loadtest/check_balancer.sh "$(terraform -chdir=terraform output -raw app_url)" 10

# 5. Al terminar
terraform -chdir=terraform destroy
```

## Pipeline CI/CD

1. **Código**: flake8 + 15 pruebas unitarias con cobertura.
2. **Terraform**: `fmt -check`, `validate` y `terraform test` con proveedor simulado.
3. **Despliegue** (solo en `main` y con la variable `AWS_DEPLOY_ENABLED=true`): se autentica con los secretos `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y `AWS_SESSION_TOKEN`, publica la app en S3, reemplaza las instancias del ASG de una en una (`scripts/despliegue_gradual.sh`), corre las pruebas de integración contra el ALB y guarda los reportes en S3.

Ninguna credencial está en el código: todas van en GitHub Secrets o en `~/.aws/credentials`.
