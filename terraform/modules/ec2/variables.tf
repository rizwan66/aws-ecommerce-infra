variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "app_sg_id" { type = string }
variable "instance_type" { type = string }
variable "desired_capacity" { type = number }
variable "min_size" { type = number }
variable "max_size" { type = number }
variable "target_group_arn" { type = string }
variable "iam_instance_profile" { type = string }
variable "db_secret_arn" { type = string }
variable "db_endpoint" { type = string }
variable "redis_endpoint" { type = string }
variable "environment" { type = string }
variable "project_name" { type = string }

variable "alb_arn_suffix" {
  description = "ALB ARN suffix for request-count scaling"
  type        = string
  default     = ""
}

variable "tg_arn_suffix" {
  description = "Target group ARN suffix for request-count scaling"
  type        = string
  default     = ""
}
