variable "aws_region" {
  description = "Región de AWS (AWS Academy permite us-east-1 y us-west-2)"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo de los nombres de todos los recursos"
  type        = string
  default     = "dgiti-ef"
}

# ---------- Red ----------
variable "availability_zones" {
  description = "Dos zonas de disponibilidad para la alta disponibilidad"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Subredes públicas: balanceador y NAT Gateway"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "app_subnet_cidrs" {
  description = "Subredes privadas de aplicación: EC2 del Auto Scaling Group"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "db_subnet_cidrs" {
  description = "Subredes privadas de datos: RDS, sin ruta a Internet"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24"]
}

# ---------- Cómputo ----------
variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "asg_min_size" {
  type    = number
  default = 2
}

variable "asg_max_size" {
  type    = number
  default = 4
}

variable "asg_desired_capacity" {
  type    = number
  default = 2
}

variable "cpu_target" {
  description = "Porcentaje de CPU promedio que mantiene el escalado automático"
  type        = number
  default     = 50
}

variable "detailed_monitoring" {
  description = "Métricas de EC2 cada 1 minuto (más rápido para escalar)"
  type        = bool
  default     = true
}

variable "instance_profile_name" {
  description = "Perfil IAM que ya trae AWS Academy (no se pueden crear roles)"
  type        = string
  default     = "LabInstanceProfile"
}

variable "app_version" {
  description = "Versión de la aplicación; al cambiarla se reemplazan las instancias"
  type        = string
  default     = "1.0.0"
}

# ---------- Base de datos ----------
variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_name" {
  type    = string
  default = "appdb"
}

variable "db_username" {
  type    = string
  default = "appuser"
}

variable "db_password" {
  description = "Contraseña de la BD. Va en terraform.tfvars, que no se sube a Git"
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[A-Za-z0-9]{8,41}$", var.db_password))
    error_message = "La contraseña debe tener de 8 a 41 caracteres, solo letras y números."
  }
}
