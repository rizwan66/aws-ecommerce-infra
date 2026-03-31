# ─── ALB Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  #checkov:skip=CKV_AWS_260:Port 80 open to internet - required for public HTTP access (HTTPS needs ACM cert)
  #checkov:skip=CKV_AWS_382:All egress required - ALB needs to reach app instances on any ephemeral port
  name        = "${var.name_prefix}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-alb-sg" }
}

# ─── App Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "app" {
  #checkov:skip=CKV_AWS_382:All egress required - instances need internet access for package updates and AWS APIs
  name        = "${var.name_prefix}-app-sg"
  description = "Security group for application instances"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP and health check from ALB only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound (for package updates, AWS APIs)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-app-sg" }
}

# ─── RDS Security Group ───────────────────────────────────────────────────────
resource "aws_security_group" "db" {
  #checkov:skip=CKV_AWS_382:Outbound needed for RDS maintenance and minor version upgrades
  name        = "${var.name_prefix}-db-sg"
  description = "Security group for RDS - app tier access only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from app tier only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-db-sg" }
}

# ─── ElastiCache Security Group ───────────────────────────────────────────────
resource "aws_security_group" "cache" {
  #checkov:skip=CKV_AWS_382:Outbound needed for ElastiCache maintenance and version upgrades
  name        = "${var.name_prefix}-cache-sg"
  description = "Security group for ElastiCache - app tier access only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from app tier only"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-cache-sg" }
}
