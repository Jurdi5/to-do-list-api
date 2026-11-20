variable "aws_region" {
  description = "AWS region used by the Learner Lab."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Project name used in AWS resource names and metric dimensions."
  type        = string
  default     = "to-do-list-api"
}

variable "github_repository" {
  description = "Public GitHub repository in owner/name format."
  type        = string
  default     = "Jurdi5/to-do-list-api"
}

variable "alert_email" {
  description = "Email address subscribed to CloudWatch alarm notifications."
  type        = string
  default     = "jorge.urdialeseduardo@gmail.com"
}

variable "db_name" {
  description = "PostgreSQL database name."
  type        = string
  default     = "todolist"
}

variable "ec2_instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t2.micro"
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "ssh_cidr" {
  description = "Optional single CIDR allowed to SSH; null disables inbound SSH."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.ssh_cidr == null || can(cidrhost(var.ssh_cidr, 0))
    error_message = "ssh_cidr must be a valid CIDR range or null."
  }
}
