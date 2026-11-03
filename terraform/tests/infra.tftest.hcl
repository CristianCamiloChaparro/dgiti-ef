# Prueba de la infraestructura con un proveedor AWS simulado (no crea nada real).
#   terraform test
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_lb" {
    defaults = {
      arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/dgiti-ef-alb/abc123"
      arn_suffix = "app/dgiti-ef-alb/abc123"
      dns_name   = "dgiti-ef-alb.example.com"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = { arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/dgiti-ef-tg/abc", arn_suffix = "targetgroup/dgiti-ef-tg/abc" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", latest_version = 1 }
  }
}

variables {
  db_password = "ClaveDePrueba123"
}

run "infraestructura_completa" {
  command = apply

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.app) == 2 && length(aws_subnet.db) == 2
    error_message = "Deben existir 6 subredes (2 públicas, 2 de app, 2 de BD)"
  }

  assert {
    condition     = toset(aws_subnet.app[*].availability_zone) == toset(var.availability_zones)
    error_message = "Las subredes de app deben estar en dos zonas distintas"
  }

  assert {
    condition     = length(aws_route_table.db.route) == 0
    error_message = "La capa de datos no debe tener ruta a Internet"
  }

  assert {
    condition     = aws_autoscaling_group.app.min_size >= 2
    error_message = "El ASG debe tener al menos 2 instancias"
  }

  assert {
    condition     = aws_launch_template.app.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 debe ser obligatorio"
  }

  assert {
    condition     = aws_db_instance.primary.publicly_accessible == false && aws_db_instance.primary.storage_encrypted
    error_message = "La BD debe ser privada y cifrada"
  }

  assert {
    condition     = aws_db_instance.replica.availability_zone != aws_db_instance.primary.availability_zone
    error_message = "La réplica debe estar en otra zona"
  }

  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.main.dashboard_body).widgets) == 8
    error_message = "El dashboard debe tener 8 gráficos"
  }
}

run "rechaza_contrasena_invalida" {
  command = plan

  variables {
    db_password = "corta"
  }

  expect_failures = [var.db_password]
}
