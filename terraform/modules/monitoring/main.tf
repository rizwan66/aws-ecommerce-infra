# ─── SNS Topic for Alerts ─────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"
  tags = { Name = "${var.name_prefix}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ─── CloudWatch Dashboard ─────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          title  = "ALB Request Count"
          period = 60
          stat   = "Sum"
          metrics = [["AWS/ApplicationELB", "RequestCount",
            "LoadBalancer", var.alb_arn_suffix]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "ALB Response Time (P99)"
          period = 60
          stat   = "p99"
          metrics = [["AWS/ApplicationELB", "TargetResponseTime",
            "LoadBalancer", var.alb_arn_suffix,
            "TargetGroup", var.tg_arn_suffix]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "ALB 5xx Errors"
          period = 60
          stat   = "Sum"
          metrics = [["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count",
            "LoadBalancer", var.alb_arn_suffix]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "ASG Instance Count"
          period = 60
          stat   = "Average"
          metrics = [["AWS/AutoScaling", "GroupInServiceInstances",
            "AutoScalingGroupName", var.asg_name]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "ASG CPU Utilization"
          period = 60
          stat   = "Average"
          metrics = [["AWS/EC2", "CPUUtilization",
            "AutoScalingGroupName", var.asg_name]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "RDS CPU & Connections"
          period = 60
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", yAxis = "right" }]
          ]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "Healthy Host Count"
          period = 60
          stat   = "Minimum"
          metrics = [["AWS/ApplicationELB", "HealthyHostCount",
            "TargetGroup", var.tg_arn_suffix,
            "LoadBalancer", var.alb_arn_suffix]]
        }
      },
      {
        type = "metric"
        properties = {
          title  = "RDS Free Storage"
          period = 300
          stat   = "Minimum"
          metrics = [["AWS/RDS", "FreeStorageSpace",
            "DBInstanceIdentifier", var.rds_identifier]]
        }
      }
    ]
  })
}

# ─── Alert 1: High 5xx Error Rate ─────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB 5xx error count exceeds threshold — investigate application health"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.name_prefix}-5xx-alarm" }
}

# ─── Alert 2: ASG CPU High ────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "asg_cpu_high" {
  alarm_name          = "${var.name_prefix}-asg-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "ASG average CPU exceeds 85% for 3 minutes"
  treat_missing_data  = "notBreaching"

  dimensions = {
    AutoScalingGroupName = var.asg_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ─── Alert 3: Unhealthy Hosts ─────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name_prefix}-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "One or more targets are unhealthy"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = var.tg_arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ─── Alert 4: RDS CPU High ────────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "RDS CPU exceeds 80%"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ─── Alert 5: RDS Low Storage ─────────────────────────────────────────────────
resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "${var.name_prefix}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Minimum"
  threshold           = 5368709120 # 5 GB in bytes
  alarm_description   = "RDS free storage below 5 GB"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = var.rds_identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

# ─── Log Groups ───────────────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "app" {
  name              = "/aws/ec2/${var.name_prefix}/app"
  retention_in_days = 30
  tags              = { Name = "${var.name_prefix}-app-logs" }
}

resource "aws_cloudwatch_log_group" "alb_access" {
  name              = "/aws/alb/${var.name_prefix}/access"
  retention_in_days = 14
  tags              = { Name = "${var.name_prefix}-alb-access-logs" }
}

# ─── AWS Config for Compliance ────────────────────────────────────────────────
resource "aws_config_configuration_recorder" "main" {
  name     = "${var.name_prefix}-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_iam_role" "config" {
  name = "${var.name_prefix}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_s3_bucket" "config" {
  bucket        = "${var.name_prefix}-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.name_prefix}-config" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_config_delivery_channel" "main" {
  name           = "${var.name_prefix}-delivery"
  s3_bucket_name = aws_s3_bucket.config.bucket
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# Managed Config Rules
resource "aws_config_config_rule" "encrypted_volumes" {
  name = "${var.name_prefix}-encrypted-volumes"
  source {
    owner             = "AWS"
    source_identifier = "ENCRYPTED_VOLUMES"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "rds_storage_encrypted" {
  name = "${var.name_prefix}-rds-storage-encrypted"
  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "iam_password_policy" {
  name = "${var.name_prefix}-iam-password-policy"
  source {
    owner             = "AWS"
    source_identifier = "IAM_PASSWORD_POLICY"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

data "aws_caller_identity" "current" {}
