output "endpoint" {
  description = "RDS endpoint"
  value       = aws_db_instance.main.address
  sensitive   = true
}

output "identifier" {
  description = "RDS identifier for CloudWatch metrics"
  value       = aws_db_instance.main.identifier
}

output "port" {
  description = "RDS port"
  value       = aws_db_instance.main.port
}
