output "instance_profile_name" {
  description = "EC2 instance profile name"
  value       = aws_iam_instance_profile.ec2.name
}

output "instance_role_arn" {
  description = "EC2 instance role ARN"
  value       = aws_iam_role.ec2_instance.arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDC role ARN"
  value       = aws_iam_role.github_actions.arn
}
