output "api_url" {
  description = "Public base URL for the API."
  value       = "http://${aws_instance.app.public_dns}"
}

output "instance_id" {
  description = "EC2 instance ID used by AWS Systems Manager."
  value       = aws_instance.app.id
}

output "instance_public_ip" {
  description = "Public EC2 address."
  value       = aws_instance.app.public_ip
}

output "ssh_private_key_pem" {
  description = "Sensitive private key for the generated EC2 key pair."
  value       = tls_private_key.ec2.private_key_pem
  sensitive   = true
}

output "database_endpoint" {
  description = "Private RDS endpoint."
  value       = aws_db_instance.app.address
}

output "database_secret_arn" {
  description = "Secrets Manager ARN containing the RDS credentials."
  value       = aws_db_instance.app.master_user_secret[0].secret_arn
}

output "sns_topic_arn" {
  description = "SNS topic used by all CloudWatch alarms."
  value       = aws_sns_topic.alarms.arn
}

output "cloudwatch_dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.app.dashboard_name
}
