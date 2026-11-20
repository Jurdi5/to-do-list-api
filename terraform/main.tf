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

resource "aws_cloudwatch_metric_alarm" "ec2_cpu" {
  alarm_name          = "${var.name}-ec2-cpu-high"
  alarm_description   = "EC2 CPU exceeded 80% for two consecutive five-minute periods."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 80
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    InstanceId = aws_instance.app.id
  }
  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "database_errors" {
  alarm_name          = "${var.name}-database-errors"
  alarm_description   = "At least one database operation failed in five minutes."
  namespace           = "ToDoListApi"
  metric_name         = "DatabaseOperationErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    Service = var.name
  }
  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "tasks_created" {
  alarm_name          = "${var.name}-unusual-task-volume"
  alarm_description   = "At least 30 tasks were created in five minutes; investigate unusual activity."
  namespace           = "ToDoListApi"
  metric_name         = "TasksCreated"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 30
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    Service = var.name
  }
  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_dashboard" "app" {
  dashboard_name = "${var.name}-dashboard"
  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "EC2 CPU utilization"
          region = var.aws_region
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Database operation errors"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = [
            ["ToDoListApi", "DatabaseOperationErrors", "Service", var.name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Tasks created"
          region = var.aws_region
          period = 300
          stat   = "Sum"
          metrics = [
            ["ToDoListApi", "TasksCreated", "Service", var.name]
          ]
        }
      }
    ]
  })
}
