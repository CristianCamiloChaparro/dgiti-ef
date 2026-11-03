#!/bin/bash
# Se ejecuta una sola vez cuando arranca cada EC2 del Auto Scaling Group.
# Terraform (templatefile) reemplaza los valores entre llaves con el signo $;
# las variables propias de bash se escriben $VAR, sin llaves.
set -euxo pipefail

# Datos de la instancia con IMDSv2 (token obligatorio)
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Código de la aplicación desde S3 (lo publican Terraform y el pipeline CI/CD)
dnf install -y python3-pip
mkdir -p /opt/app
aws s3 cp "s3://${bucket}/app/" /opt/app/ --recursive --region "${region}"
python3 -m pip install -r /opt/app/requirements.txt

cat > /etc/app.env <<EOF
INSTANCE_ID=$INSTANCE_ID
AZ=$AZ
APP_VERSION=${app_version}
DB_HOST=${db_host}
DB_REPLICA_HOST=${db_replica_host}
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASSWORD=${db_password}
EOF
chmod 600 /etc/app.env

cat > /etc/systemd/system/app.service <<'EOF'
[Unit]
Description=Servicio DGITI (gunicorn en el puerto 8080)
After=network-online.target

[Service]
EnvironmentFile=/etc/app.env
WorkingDirectory=/opt/app
ExecStart=/usr/bin/python3 -m gunicorn --workers 2 --threads 4 --bind 0.0.0.0:8080 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now app.service
