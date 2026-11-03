output "app_url" {
  description = "URL pública del servicio (a través del balanceador)"
  value       = "http://${aws_lb.app.dns_name}"
}

output "health_url" {
  value = "http://${aws_lb.app.dns_name}/health"
}

output "availability_zones" {
  description = "Zonas usadas, separadas por coma (las usa la prueba k6)"
  value       = join(",", local.azs)
}

output "asg_name" {
  value = aws_autoscaling_group.app.name
}

output "db_primary_endpoint" {
  description = "Endpoint privado de la BD primaria (solo accesible desde la VPC)"
  value       = aws_db_instance.primary.address
}

output "db_replica_endpoint" {
  description = "Endpoint privado de la réplica de lectura"
  value       = aws_db_instance.replica.address
}

output "artifacts_bucket" {
  value = terraform_data.artifacts_bucket.output
}

output "dashboard_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}
