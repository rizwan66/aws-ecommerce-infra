locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

# ─── Secrets Manager: DB password ─────────────────────────────────────────────
resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${local.name_prefix}/db-password"
  description             = "RDS master password"
  recovery_window_in_days = 7

  tags = {
    Name = "${local.name_prefix}-db-password"
  }
}

resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db_password.result
}

# ─── VPC & Networking ─────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  name_prefix          = local.name_prefix
  vpc_cidr             = var.vpc_cidr
  availability_zones   = var.availability_zones
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  data_subnet_cidrs    = var.data_subnet_cidrs
}

# ─── IAM ──────────────────────────────────────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  name_prefix        = local.name_prefix
  db_secret_arn      = aws_secretsmanager_secret.db_password.arn
}

# ─── Security Groups ──────────────────────────────────────────────────────────
module "security" {
  source = "./modules/security"

  name_prefix = local.name_prefix
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.vpc_cidr
}

# ─── Application Load Balancer ────────────────────────────────────────────────
module "alb" {
  source = "./modules/alb"

  name_prefix       = local.name_prefix
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.security.alb_sg_id
}

# ─── EC2 / Auto Scaling Group ─────────────────────────────────────────────────
module "ec2" {
  source = "./modules/ec2"

  name_prefix          = local.name_prefix
  vpc_id               = module.vpc.vpc_id
  private_subnet_ids   = module.vpc.private_subnet_ids
  app_sg_id            = module.security.app_sg_id
  instance_type        = var.app_instance_type
  desired_capacity     = var.app_instance_count
  min_size             = var.app_min_size
  max_size             = var.app_max_size
  target_group_arn     = module.alb.target_group_arn
  iam_instance_profile = module.iam.instance_profile_name
  db_secret_arn         = aws_secretsmanager_secret.db_password.arn
  db_endpoint           = module.rds.endpoint
  redis_endpoint        = module.elasticache.endpoint
  environment           = var.environment
  project_name          = var.project_name
  artifacts_bucket_name = aws_s3_bucket.artifacts.bucket
  alb_arn_suffix        = module.alb.alb_arn_suffix
  tg_arn_suffix         = module.alb.tg_arn_suffix
}

# ─── RDS PostgreSQL ───────────────────────────────────────────────────────────
module "rds" {
  source = "./modules/rds"

  name_prefix          = local.name_prefix
  vpc_id               = module.vpc.vpc_id
  data_subnet_ids      = module.vpc.data_subnet_ids
  db_sg_id             = module.security.db_sg_id
  instance_class       = var.db_instance_class
  allocated_storage    = var.db_allocated_storage
  db_name              = var.db_name
  db_username          = var.db_username
  db_password          = random_password.db_password.result
  environment          = var.environment
}

# ─── ElastiCache Redis ────────────────────────────────────────────────────────
module "elasticache" {
  source = "./modules/elasticache"

  name_prefix        = local.name_prefix
  vpc_id             = module.vpc.vpc_id
  data_subnet_ids    = module.vpc.data_subnet_ids
  cache_sg_id        = module.security.cache_sg_id
  node_type          = var.cache_node_type
  num_cache_nodes    = var.cache_num_nodes
}

# ─── Monitoring & Alerting ────────────────────────────────────────────────────
module "monitoring" {
  source = "./modules/monitoring"

  name_prefix     = local.name_prefix
  asg_name        = module.ec2.asg_name
  alb_arn_suffix  = module.alb.alb_arn_suffix
  tg_arn_suffix   = module.alb.tg_arn_suffix
  rds_identifier  = module.rds.identifier
  alert_email     = var.alert_email
  environment     = var.environment
}
