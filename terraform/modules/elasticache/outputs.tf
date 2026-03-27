output "endpoint" {
  description = "Primary ElastiCache endpoint"
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
  sensitive   = true
}

output "reader_endpoint" {
  description = "Reader endpoint for read replicas"
  value       = aws_elasticache_replication_group.main.reader_endpoint_address
  sensitive   = true
}

output "port" {
  description = "Redis port"
  value       = aws_elasticache_replication_group.main.port
}
