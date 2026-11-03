data "aws_caller_identity" "current" {}

# Amazon Linux 2023 más reciente al momento del primer apply.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  name = var.project_name
  azs  = var.availability_zones
}

# =====================================================================
# 1. RED: VPC, 6 subredes en 2 zonas, Internet Gateway y NAT Gateway
# =====================================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(local.azs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = { Name = "${local.name}-public-${local.azs[count.index]}", Tier = "public" }
}

resource "aws_subnet" "app" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-app-${local.azs[count.index]}", Tier = "app" }
}

resource "aws_subnet" "db" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = { Name = "${local.name}-db-${local.azs[count.index]}", Tier = "db" }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

# Un solo NAT Gateway por costo del laboratorio (en producción, uno por zona).
resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${local.name}-rt-public" }
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = { Name = "${local.name}-rt-app" }
}

# Tabla de la capa de datos: solo la ruta local de la VPC, sin Internet.
resource "aws_route_table" "db" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-rt-db" }
}

resource "aws_route_table_association" "public" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "db" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.db[count.index].id
  route_table_id = aws_route_table.db.id
}

# Las EC2 privadas llegan a S3 sin pasar por Internet.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.app.id]
  tags              = { Name = "${local.name}-s3-endpoint" }
}

# =====================================================================
# 2. SEGURIDAD: Security Groups encadenados ALB -> App -> BD
# =====================================================================
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb-sg"
  description = "ALB: HTTP 80 desde Internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Hacia las EC2 de la aplicacion"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${local.name}-alb-sg" }
}

resource "aws_security_group" "app" {
  name        = "${local.name}-app-sg"
  description = "EC2: puerto 8080 solo desde el ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App solo desde el ALB"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Salida: NAT (paquetes), S3 y BD"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name}-app-sg" }
}

resource "aws_security_group" "db" {
  name        = "${local.name}-db-sg"
  description = "RDS: MySQL 3306 solo desde las EC2 de la app"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "MySQL solo desde el SG de la aplicacion"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = { Name = "${local.name}-db-sg" }
}

# =====================================================================
# 3. BASE DE DATOS: RDS MySQL primaria + réplica de lectura en otra zona
# =====================================================================
resource "aws_db_subnet_group" "db" {
  name       = "${local.name}-db-subnets"
  subnet_ids = aws_subnet.db[*].id
  tags       = { Name = "${local.name}-db-subnets" }
}

resource "aws_db_instance" "primary" {
  identifier              = "${local.name}-db"
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = var.db_instance_class
  allocated_storage       = 20
  storage_type            = "gp2"
  storage_encrypted       = true
  db_name                 = var.db_name
  username                = var.db_username
  password                = var.db_password
  db_subnet_group_name    = aws_db_subnet_group.db.name
  vpc_security_group_ids  = [aws_security_group.db.id]
  availability_zone       = local.azs[0]
  multi_az                = false
  publicly_accessible     = false
  backup_retention_period = 1 # requisito para crear la réplica
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = { Name = "${local.name}-db" }
}

resource "aws_db_instance" "replica" {
  identifier             = "${local.name}-db-replica"
  replicate_source_db    = aws_db_instance.primary.identifier
  instance_class         = var.db_instance_class
  storage_encrypted      = true
  vpc_security_group_ids = [aws_security_group.db.id]
  availability_zone      = local.azs[1]
  publicly_accessible    = false
  skip_final_snapshot    = true
  apply_immediately      = true

  tags = { Name = "${local.name}-db-replica" }
}

# =====================================================================
# 4. ALMACENAMIENTO: bucket S3 con el código de la app y los reportes de CI
# =====================================================================
# AWS Academy prohíbe s3:GetBucketObjectLockConfiguration, que el recurso
# aws_s3_bucket necesita para leer el bucket. Por eso Terraform crea (y en
# destroy elimina) el bucket con la AWS CLI, y bloquea el acceso público.
resource "terraform_data" "artifacts_bucket" {
  input = "${local.name}-artifacts-${data.aws_caller_identity.current.account_id}"

  provisioner "local-exec" {
    command = "aws s3api create-bucket --bucket ${self.input} --region ${var.aws_region} && aws s3api put-public-access-block --bucket ${self.input} --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws s3 rb s3://${self.input} --force"
  }
}

resource "aws_s3_object" "app" {
  for_each = fileset("${path.module}/../app", "*")

  bucket = terraform_data.artifacts_bucket.output
  key    = "app/${each.value}"
  source = "${path.module}/../app/${each.value}"
  etag   = filemd5("${path.module}/../app/${each.value}")
}

# =====================================================================
# 5. BALANCEADOR: Application Load Balancer con health check /health
# =====================================================================
resource "aws_lb" "app" {
  name               = "${local.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${local.name}-alb" }
}

resource "aws_lb_target_group" "app" {
  name                 = "${local.name}-tg"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = aws_vpc.main.id
  target_type          = "instance"
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${local.name}-tg" }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# =====================================================================
# 6. CÓMPUTO: Launch Template + Auto Scaling Group (2 a 4 EC2 privadas)
# =====================================================================
resource "aws_launch_template" "app" {
  name_prefix            = "${local.name}-lt-"
  image_id               = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.app.id]
  update_default_version = true

  iam_instance_profile {
    name = var.instance_profile_name
  }

  # IMDSv2 obligatorio
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  monitoring {
    enabled = var.detailed_monitoring
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh", {
    region          = var.aws_region
    bucket          = terraform_data.artifacts_bucket.output
    app_version     = var.app_version
    db_host         = aws_db_instance.primary.address
    db_replica_host = aws_db_instance.replica.address
    db_name         = var.db_name
    db_user         = var.db_username
    db_password     = var.db_password
  }))

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${local.name}-app" }
  }

  # Que una AMI nueva publicada por AWS no cambie el plan.
  lifecycle {
    ignore_changes = [image_id]
  }
}

# En una cuenta nueva el rol vinculado de Auto Scaling todavía no existe; si
# AWS lo crea junto con el ASG, los primeros lanzamientos fallan porque el rol
# aún no está disponible. Se crea antes y se esperan 30 s (si ya existe, el
# error de la CLI se ignora).
resource "terraform_data" "autoscaling_service_role" {
  provisioner "local-exec" {
    command    = "aws iam create-service-linked-role --aws-service-name autoscaling.amazonaws.com"
    on_failure = continue
  }
}

resource "time_sleep" "autoscaling_service_role" {
  create_duration = "30s"
  depends_on      = [terraform_data.autoscaling_service_role]
}

resource "aws_autoscaling_group" "app" {
  name                      = "${local.name}-asg"
  min_size                  = var.asg_min_size
  max_size                  = var.asg_max_size
  desired_capacity          = var.asg_desired_capacity
  vpc_zone_identifier       = aws_subnet.app[*].id
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 240
  metrics_granularity       = "1Minute"
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
  ]

  launch_template {
    id      = aws_launch_template.app.id
    version = aws_launch_template.app.latest_version
  }

  # Al cambiar el Launch Template, reemplaza las instancias de a poco.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-app"
    propagate_at_launch = true
  }

  # El escalado automático cambia la capacidad deseada; Terraform no la revierte.
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  depends_on = [aws_s3_object.app, aws_route_table_association.app, time_sleep.autoscaling_service_role]
}

resource "aws_autoscaling_policy" "cpu" {
  name                      = "${local.name}-cpu-target"
  autoscaling_group_name    = aws_autoscaling_group.app.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 120

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = var.cpu_target
  }
}

# =====================================================================
# 7. MONITOREO: dashboard de CloudWatch
# =====================================================================
locals {
  alb_dim = ["LoadBalancer", aws_lb.app.arn_suffix]
  tg_dim  = ["TargetGroup", aws_lb_target_group.app.arn_suffix]
  asg_dim = ["AutoScalingGroupName", aws_autoscaling_group.app.name]

  widgets = [
    {
      title   = "Solicitudes al balanceador (por minuto)"
      stat    = "Sum"
      metrics = [concat(["AWS/ApplicationELB", "RequestCount"], local.alb_dim)]
    },
    {
      title   = "Tiempo de respuesta p95 (segundos)"
      stat    = "p95"
      metrics = [concat(["AWS/ApplicationELB", "TargetResponseTime"], local.alb_dim)]
    },
    {
      title = "Códigos HTTP"
      stat  = "Sum"
      metrics = [
        concat(["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count"], local.alb_dim),
        concat(["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count"], local.alb_dim),
        concat(["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count"], local.alb_dim),
      ]
    },
    {
      title = "Solicitudes por instancia y targets sanos"
      stat  = "Sum"
      metrics = [
        concat(["AWS/ApplicationELB", "RequestCountPerTarget"], local.tg_dim),
        concat(["AWS/ApplicationELB", "HealthyHostCount"], local.tg_dim, local.alb_dim, [{ stat = "Minimum", yAxis = "right" }]),
      ]
    },
    {
      title       = "CPU promedio del Auto Scaling Group (%)"
      stat        = "Average"
      metrics     = [concat(["AWS/EC2", "CPUUtilization"], local.asg_dim)]
      annotations = { horizontal = [{ label = "Objetivo de escalado", value = var.cpu_target }] }
    },
    {
      title   = "Instancias en servicio del ASG"
      stat    = "Maximum"
      metrics = [concat(["AWS/AutoScaling", "GroupInServiceInstances"], local.asg_dim)]
    },
    {
      title = "CPU de RDS: primaria y réplica (%)"
      stat  = "Average"
      metrics = [
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.primary.identifier],
        ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", aws_db_instance.replica.identifier],
      ]
    },
    {
      title   = "Retraso de la réplica (segundos)"
      stat    = "Maximum"
      metrics = [["AWS/RDS", "ReplicaLag", "DBInstanceIdentifier", aws_db_instance.replica.identifier]]
    },
  ]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-dashboard"

  # Rango por defecto de 6 horas: se ven la prueba previa y la del video.
  dashboard_body = jsonencode({
    start = "-PT6H"
    widgets = [
      for i, w in local.widgets : {
        type   = "metric"
        x      = (i % 2) * 12
        y      = floor(i / 2) * 6
        width  = 12
        height = 6
        properties = merge({
          title   = w.title
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = w.stat
          metrics = w.metrics
        }, try({ annotations = w.annotations }, {}))
      }
    ]
  })
}
