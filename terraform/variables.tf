variable "aws_region" {
  description = "Primary AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "ecommerce"
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "prod"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be dev, staging, or prod."
  }
}

variable "cost_center" {
  description = "Cost center for billing allocation"
  type        = string
  default     = "engineering"
}

# Network
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for multi-AZ deployment"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (app tier)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "data_subnet_cidrs" {
  description = "CIDR blocks for data subnets (DB tier)"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

# Compute
variable "app_instance_type" {
  description = "EC2 instance type for application servers"
  type        = string
  default     = "t3.small"
}

variable "app_instance_count" {
  description = "Desired number of application instances"
  type        = number
  default     = 3
  validation {
    condition     = var.app_instance_count >= 3
    error_message = "Minimum 3 instances required for multi-AZ HA."
  }
}

variable "app_min_size" {
  description = "Minimum instances in ASG"
  type        = number
  default     = 3
}

variable "app_max_size" {
  description = "Maximum instances in ASG"
  type        = number
  default     = 9
}

# Database
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Name of the database"
  type        = string
  default     = "ecommercedb"
}

variable "db_username" {
  description = "Master username for RDS (fetched from Secrets Manager)"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

# Cache
variable "cache_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "cache_num_nodes" {
  description = "Number of ElastiCache nodes"
  type        = number
  default     = 2
}

# Alerting
variable "alert_email" {
  description = "Email address for CloudWatch alerts"
  type        = string
  default     = "alerts@example.com"
}

# DR
variable "dr_region" {
  description = "Disaster recovery region"
  type        = string
  default     = "us-west-2"
}
