# ─── SNS Topic for Alerts ─────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  #checkov:skip=CKV_AWS_26:Using AWS-managed encryption - CMK not required for alert notifications
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

      # ── Section header: Golden Signals ─────────────────────────────────────
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "## Golden Signals — Latency | Traffic | Errors | Saturation"
        }
      },

      # ── SIGNAL 1: LATENCY ──────────────────────────────────────────────────
      # How long it takes to service a request.
      # P50/P95/P99 on the same graph reveals latency distribution.
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 8
        height = 6
        properties = {
          title   = "[Latency] Target Response Time"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.tg_arn_suffix, { stat = "p50", label = "P50", color = "#2ca02c" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.tg_arn_suffix, { stat = "p95", label = "P95", color = "#ff7f0e" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.tg_arn_suffix, { stat = "p99", label = "P99", color = "#d62728" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.tg_arn_suffix, { stat = "p100", label = "Max", color = "#9467bd" }]
          ]
          yAxis = { left = { label = "seconds", min = 0 } }
          annotations = {
            horizontal = [{ label = "SLO 500ms", value = 0.5, color = "#d62728" }]
          }
        }
      },

      # ── SIGNAL 2: TRAFFIC ──────────────────────────────────────────────────
      # How much demand is being placed on the system (requests per minute).
      {
        type   = "metric"
        x      = 8
        y      = 1
        width  = 8
        height = 6
        properties = {
          title   = "[Traffic] Requests by Status Class"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Total", color = "#1f77b4" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "2xx Success", color = "#2ca02c" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "4xx Client", color = "#ff7f0e" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "5xx Server", color = "#d62728" }]
          ]
          yAxis = { left = { label = "requests / min", min = 0 } }
        }
      },

      # ── SIGNAL 3: ERRORS ───────────────────────────────────────────────────
      # The rate of requests that fail (5xx from ALB and app targets).
      {
        type   = "metric"
        x      = 16
        y      = 1
        width  = 8
        height = 6
        properties = {
          title   = "[Errors] 5xx Rate & Unhealthy Hosts"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "ALB 5xx", color = "#d62728" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Target 5xx", color = "#ff7f0e" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Target 4xx", color = "#bcbd22" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.tg_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { stat = "Maximum", label = "Unhealthy Hosts", color = "#9467bd", yAxis = "right" }]
          ]
          yAxis = {
            left  = { label = "error count / min", min = 0 }
            right = { label = "unhealthy hosts", min = 0 }
          }
          annotations = {
            horizontal = [{ label = "Alert threshold", value = 10, color = "#d62728" }]
          }
        }
      },

      # ── SIGNAL 4: SATURATION — EC2 CPU ─────────────────────────────────────
      # How full the app tier is; triggers auto-scaling at 70%.
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 6
        height = 6
        properties = {
          title   = "[Saturation] EC2 CPU Utilization"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name, { stat = "Average", label = "Avg CPU", color = "#1f77b4" }],
            ["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", var.asg_name, { stat = "Maximum", label = "Max CPU", color = "#d62728" }]
          ]
          yAxis = { left = { label = "percent", min = 0, max = 100 } }
          annotations = {
            horizontal = [{ label = "Scale-out at 70%", value = 70, color = "#ff7f0e" }]
          }
        }
      },

      # ── SIGNAL 4: SATURATION — ASG Scale ───────────────────────────────────
      # Horizontal scaling head-room: how close to max capacity.
      {
        type   = "metric"
        x      = 6
        y      = 7
        width  = 6
        height = 6
        properties = {
          title   = "[Saturation] ASG Instance Count"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", var.asg_name, { stat = "Average", label = "In Service", color = "#2ca02c" }],
            ["AWS/AutoScaling", "GroupPendingInstances", "AutoScalingGroupName", var.asg_name, { stat = "Average", label = "Pending", color = "#ff7f0e" }],
            ["AWS/AutoScaling", "GroupTerminatingInstances", "AutoScalingGroupName", var.asg_name, { stat = "Average", label = "Terminating", color = "#d62728" }]
          ]
          yAxis = { left = { label = "instances", min = 0 } }
          annotations = {
            horizontal = [{ label = "Max capacity (9)", value = 9, color = "#d62728" }]
          }
        }
      },

      # ── SIGNAL 4: SATURATION — RDS CPU & Connections ───────────────────────
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 6
        height = 6
        properties = {
          title   = "[Saturation] RDS CPU & Connections"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "CPU %", color = "#1f77b4" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "Connections", color = "#ff7f0e", yAxis = "right" }]
          ]
          yAxis = {
            left  = { label = "cpu percent", min = 0, max = 100 }
            right = { label = "connections", min = 0 }
          }
          annotations = {
            horizontal = [{ label = "CPU alert at 80%", value = 80, color = "#d62728" }]
          }
        }
      },

      # ── SIGNAL 4: SATURATION — RDS Disk & IOPS ─────────────────────────────
      {
        type   = "metric"
        x      = 18
        y      = 7
        width  = 6
        height = 6
        properties = {
          title   = "[Saturation] RDS Free Storage & IOPS"
          region  = data.aws_region.current.name
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_identifier, { stat = "Minimum", label = "Free Storage (bytes)", color = "#2ca02c" }],
            ["AWS/RDS", "ReadIOPS", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "Read IOPS", color = "#1f77b4", yAxis = "right" }],
            ["AWS/RDS", "WriteIOPS", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "Write IOPS", color = "#ff7f0e", yAxis = "right" }]
          ]
          yAxis = {
            left  = { label = "bytes free", min = 0 }
            right = { label = "iops", min = 0 }
          }
          annotations = {
            horizontal = [{ label = "Alert < 2 GB", value = 2147483648, color = "#d62728" }]
          }
        }
      },

      # ── CONTEXT: Healthy / Unhealthy Hosts ─────────────────────────────────
      {
        type   = "metric"
        x      = 0
        y      = 13
        width  = 8
        height = 6
        properties = {
          title   = "[Context] Healthy vs Unhealthy Hosts"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", var.tg_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { stat = "Minimum", label = "Healthy", color = "#2ca02c" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", var.tg_arn_suffix, "LoadBalancer", var.alb_arn_suffix, { stat = "Maximum", label = "Unhealthy", color = "#d62728" }]
          ]
          yAxis = { left = { label = "hosts", min = 0 } }
        }
      },

      # ── CONTEXT: ALB Connection Depth ──────────────────────────────────────
      {
        type   = "metric"
        x      = 8
        y      = 13
        width  = 8
        height = 6
        properties = {
          title   = "[Context] ALB Active & New Connections"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "ActiveConnectionCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "Active", color = "#1f77b4" }],
            ["AWS/ApplicationELB", "NewConnectionCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum", label = "New", color = "#ff7f0e" }]
          ]
          yAxis = { left = { label = "connections", min = 0 } }
        }
      },

      # ── CONTEXT: RDS Network & Query Latency ───────────────────────────────
      {
        type   = "metric"
        x      = 16
        y      = 13
        width  = 8
        height = 6
        properties = {
          title   = "[Context] RDS Network & Query Latency"
          region  = data.aws_region.current.name
          period  = 60
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/RDS", "NetworkReceiveThroughput", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "Network In", color = "#1f77b4" }],
            ["AWS/RDS", "NetworkTransmitThroughput", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "Network Out", color = "#ff7f0e" }],
            ["AWS/RDS", "ReadLatency", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "Read Latency (s)", color = "#2ca02c", yAxis = "right" }],
            ["AWS/RDS", "WriteLatency", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "Write Latency (s)", color = "#d62728", yAxis = "right" }]
          ]
          yAxis = {
            left  = { label = "bytes/sec", min = 0 }
            right = { label = "seconds", min = 0 }
          }
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
  #checkov:skip=CKV_AWS_338:30-day retention sufficient for this environment; increase for compliance
  #checkov:skip=CKV_AWS_158:Using CloudWatch default encryption - CMK not required for this environment
  name              = "/aws/ec2/${var.name_prefix}/app"
  retention_in_days = 30
  tags              = { Name = "${var.name_prefix}-app-logs" }
}

resource "aws_cloudwatch_log_group" "alb_access" {
  #checkov:skip=CKV_AWS_338:14-day retention sufficient for ALB access logs; increase for compliance
  #checkov:skip=CKV_AWS_158:Using CloudWatch default encryption - CMK not required for this environment
  name              = "/aws/alb/${var.name_prefix}/access"
  retention_in_days = 14
  tags              = { Name = "${var.name_prefix}-alb-access-logs" }
}

# ─── AWS Config: use existing account recorder ────────────────────────────────
# Config recorder is account-scoped (limit=1). Manage it via the AWS Console
# or import the existing recorder if you need Terraform to control it.

# ─── Alert 6: Redis High Evictions (cache saturation) ─────────────────────────
resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  alarm_name          = "${var.name_prefix}-redis-evictions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Sum"
  threshold           = 100
  alarm_description   = "Redis eviction rate exceeds 100/min — cache memory saturated, consider scaling node type"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ReplicationGroupId = var.elasticache_replication_group_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.name_prefix}-redis-evictions-alarm" }
}

# ─── Alert 7: ALB P99 Latency > 1s (latency SLO breach) ──────────────────────
resource "aws_cloudwatch_metric_alarm" "alb_latency_p99" {
  alarm_name          = "${var.name_prefix}-alb-latency-p99"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  extended_statistic  = "p99"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  threshold           = 1.0
  alarm_description   = "P99 response time exceeds 1 second for 3 consecutive minutes — latency SLO breach"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.tg_arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Name = "${var.name_prefix}-latency-p99-alarm" }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
