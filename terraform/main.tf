terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "to-do-list-p4-state"
    key          = "to-do-list-api/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0, < 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "amazon_linux_2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "tls_private_key" "ec2" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "app" {
  key_name   = "${var.name}-key"
  public_key = tls_private_key.ec2.public_key_openssh
}

resource "aws_security_group" "app" {
  name        = "${var.name}-app"
  description = "HTTP access to the to-do-list API"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP API"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  dynamic "ingress" {
    for_each = var.ssh_cidr == null ? [] : [var.ssh_cidr]
    content {
      description = "Optional SSH administration"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.name}-app"
    Project = var.name
  }
}

resource "aws_security_group" "database" {
  name        = "${var.name}-database"
  description = "PostgreSQL access from the API instance only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL from API"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  tags = {
    Name    = "${var.name}-database"
    Project = var.name
  }
}

resource "aws_db_subnet_group" "app" {
  name       = "${var.name}-database"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name    = "${var.name}-database"
    Project = var.name
  }
}

resource "aws_db_instance" "app" {
  identifier                  = "${var.name}-database"
  engine                      = "postgres"
  instance_class              = var.db_instance_class
  allocated_storage           = 20
  storage_type                = "gp3"
  db_name                     = var.db_name
  username                    = "todo_admin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.app.name
  vpc_security_group_ids      = [aws_security_group.database.id]
  publicly_accessible         = false
  storage_encrypted           = true
  backup_retention_period     = 0
  auto_minor_version_upgrade  = true
  skip_final_snapshot         = true
  deletion_protection         = false

  tags = {
    Name    = "${var.name}-database"
    Project = var.name
  }
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.amazon_linux_2023.value
  instance_type               = var.ec2_instance_type
  subnet_id                   = data.aws_subnets.default.ids[0]
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = aws_key_pair.app.key_name
  iam_instance_profile        = var.lab_instance_profile_name
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region        = var.aws_region
    db_host           = aws_db_instance.app.address
    db_name           = var.db_name
    db_port           = aws_db_instance.app.port
    db_secret_arn     = aws_db_instance.app.master_user_secret[0].secret_arn
    github_repository = var.github_repository
    app_name          = var.name
    metrics_namespace = "ToDoListApi"
    metrics_service   = var.name
  })
  user_data_replace_on_change = true

  tags = {
    Name    = var.name
    Project = var.name
  }
}

resource "aws_sns_topic" "alarms" {
  name = "${var.name}-alarms"

  tags = {
    Project = var.name
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

locals {
  cloudwatch_alarms = jsondecode(templatefile("${path.module}/../alerting/alarms.json", {
    name          = var.name
    instance_id   = aws_instance.app.id
    sns_topic_arn = aws_sns_topic.alarms.arn
  }))
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  alarm_name          = local.cloudwatch_alarms.ec2_cpu.alarm_name
  alarm_description   = local.cloudwatch_alarms.ec2_cpu.alarm_description
  namespace           = local.cloudwatch_alarms.ec2_cpu.namespace
  metric_name         = local.cloudwatch_alarms.ec2_cpu.metric_name
  statistic           = local.cloudwatch_alarms.ec2_cpu.statistic
  period              = local.cloudwatch_alarms.ec2_cpu.period
  evaluation_periods  = local.cloudwatch_alarms.ec2_cpu.evaluation_periods
  datapoints_to_alarm = local.cloudwatch_alarms.ec2_cpu.datapoints_to_alarm
  threshold           = local.cloudwatch_alarms.ec2_cpu.threshold
  comparison_operator = local.cloudwatch_alarms.ec2_cpu.comparison_operator
  treat_missing_data  = local.cloudwatch_alarms.ec2_cpu.treat_missing_data
  dimensions          = local.cloudwatch_alarms.ec2_cpu.dimensions
  alarm_actions       = local.cloudwatch_alarms.ec2_cpu.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "database_errors" {
  alarm_name          = local.cloudwatch_alarms.database_errors.alarm_name
  alarm_description   = local.cloudwatch_alarms.database_errors.alarm_description
  namespace           = local.cloudwatch_alarms.database_errors.namespace
  metric_name         = local.cloudwatch_alarms.database_errors.metric_name
  statistic           = local.cloudwatch_alarms.database_errors.statistic
  period              = local.cloudwatch_alarms.database_errors.period
  evaluation_periods  = local.cloudwatch_alarms.database_errors.evaluation_periods
  datapoints_to_alarm = local.cloudwatch_alarms.database_errors.datapoints_to_alarm
  threshold           = local.cloudwatch_alarms.database_errors.threshold
  comparison_operator = local.cloudwatch_alarms.database_errors.comparison_operator
  treat_missing_data  = local.cloudwatch_alarms.database_errors.treat_missing_data
  dimensions          = local.cloudwatch_alarms.database_errors.dimensions
  alarm_actions       = local.cloudwatch_alarms.database_errors.alarm_actions
}

resource "aws_cloudwatch_metric_alarm" "tasks_created" {
  alarm_name          = local.cloudwatch_alarms.tasks_created.alarm_name
  alarm_description   = local.cloudwatch_alarms.tasks_created.alarm_description
  namespace           = local.cloudwatch_alarms.tasks_created.namespace
  metric_name         = local.cloudwatch_alarms.tasks_created.metric_name
  statistic           = local.cloudwatch_alarms.tasks_created.statistic
  period              = local.cloudwatch_alarms.tasks_created.period
  evaluation_periods  = local.cloudwatch_alarms.tasks_created.evaluation_periods
  datapoints_to_alarm = local.cloudwatch_alarms.tasks_created.datapoints_to_alarm
  threshold           = local.cloudwatch_alarms.tasks_created.threshold
  comparison_operator = local.cloudwatch_alarms.tasks_created.comparison_operator
  treat_missing_data  = local.cloudwatch_alarms.tasks_created.treat_missing_data
  dimensions          = local.cloudwatch_alarms.tasks_created.dimensions
  alarm_actions       = local.cloudwatch_alarms.tasks_created.alarm_actions
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "${var.name}-dashboard"
  dashboard_body = templatefile("${path.module}/../alerting/cloudwatch-dashboard.json", {
    region      = var.aws_region
    instance_id = aws_instance.app.id
    service     = var.name
  })
}
