output "alb_dns_name" {
  description = "DNS name of the ALB"
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Zone ID of the ALB"
  value       = aws_lb.main.zone_id
}

output "alb_arn" {
  description = "ARN of the ALB"
  value       = aws_lb.main.arn
}

output "alb_arn_suffix" {
  description = "ARN suffix for CloudWatch metrics"
  value       = aws_lb.main.arn_suffix
}

output "target_group_arn" {
  description = "Target group ARN"
  value       = aws_lb_target_group.app.arn
}

output "tg_arn_suffix" {
  description = "Target group ARN suffix for CloudWatch metrics"
  value       = aws_lb_target_group.app.arn_suffix
}
