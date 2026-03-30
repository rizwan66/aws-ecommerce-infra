data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─── Launch Template ──────────────────────────────────────────────────────────
resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-app-lt-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = var.iam_instance_profile
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [var.app_sg_id]
    delete_on_termination       = true
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 enforced
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.name_prefix}-app"
      Environment = var.environment
      Project     = var.project_name
    }
  }

  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    db_secret_arn         = var.db_secret_arn
    db_endpoint           = var.db_endpoint
    redis_endpoint        = var.redis_endpoint
    environment           = var.environment
    project_name          = var.project_name
    aws_region            = data.aws_region.current.name
    artifacts_bucket_name = var.artifacts_bucket_name
  }))

  lifecycle {
    create_before_destroy = true
  }
}

data "aws_region" "current" {}

# ─── Auto Scaling Group ───────────────────────────────────────────────────────
resource "aws_autoscaling_group" "app" {
  name                      = "${var.name_prefix}-app-asg"
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [var.target_group_arn]
  health_check_type         = "ELB"
  health_check_grace_period = 120

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 66
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-app"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── CPU Scaling Policy ───────────────────────────────────────────────────────
resource "aws_autoscaling_policy" "cpu_scale_out" {
  name                   = "${var.name_prefix}-cpu-scale-out"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

# ─── Request Count Scaling Policy ─────────────────────────────────────────────
resource "aws_autoscaling_policy" "request_count" {
  count = var.alb_arn_suffix != "" && var.tg_arn_suffix != "" ? 1 : 0

  name                   = "${var.name_prefix}-request-count"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${var.tg_arn_suffix}"
    }
    target_value = 1000.0
  }
}
