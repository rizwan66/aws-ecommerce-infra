output "alb_sg_id" {
  description = "ALB security group ID"
  value       = aws_security_group.alb.id
}

output "app_sg_id" {
  description = "Application security group ID"
  value       = aws_security_group.app.id
}

output "db_sg_id" {
  description = "Database security group ID"
  value       = aws_security_group.db.id
}

output "cache_sg_id" {
  description = "ElastiCache security group ID"
  value       = aws_security_group.cache.id
}
