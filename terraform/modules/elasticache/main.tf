resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name_prefix}-cache-subnet-group"
  subnet_ids = var.data_subnet_ids
  tags       = { Name = "${var.name_prefix}-cache-subnet-group" }
}

resource "aws_elasticache_parameter_group" "redis" {
  name   = "${var.name_prefix}-redis7-params"
  family = "redis7"

  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }

  tags = { Name = "${var.name_prefix}-redis-params" }
}

resource "aws_elasticache_replication_group" "main" {
  #checkov:skip=CKV_AWS_31:Auth token not required - Redis is accessible only within the VPC via security groups
  #checkov:skip=CKV_AWS_191:Using AWS-managed encryption key - CMK not required for this environment
  replication_group_id = "${var.name_prefix}-redis"
  description          = "Redis cluster for ${var.name_prefix}"

  node_type            = var.node_type
  num_cache_clusters   = var.num_cache_nodes
  parameter_group_name = aws_elasticache_parameter_group.redis.name
  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [var.cache_sg_id]

  engine         = "redis"
  engine_version = "7.1"
  port           = 6379

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  automatic_failover_enabled = var.num_cache_nodes > 1

  snapshot_retention_limit = 1
  snapshot_window          = "05:00-06:00"
  maintenance_window       = "mon:06:00-mon:07:00"

  auto_minor_version_upgrade = true

  tags = { Name = "${var.name_prefix}-redis" }
}
