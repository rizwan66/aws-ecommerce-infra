# Cost Optimization & FinOps

## Monthly Cost Projection (us-east-1, prod)

| Resource | Config | Estimated $/month |
|----------|--------|-------------------|
| EC2 (3× t3.small, On-Demand) | 3 × $0.0208/hr | ~$45 |
| NAT Gateway (3× AZ) | 3 × $0.045/hr + data | ~$100 |
| ALB | $0.008/hr + LCU | ~$20 |
| RDS PostgreSQL Multi-AZ (db.t3.medium) | $0.068/hr | ~$50 |
| ElastiCache Redis (2× cache.t3.micro) | $0.017/hr each | ~$25 |
| S3 (state + logs + artifacts) | ~50 GB | ~$5 |
| CloudWatch (metrics + logs + dashboard) | standard tier | ~$20 |
| Secrets Manager | 2 secrets | ~$1 |
| Data Transfer | ~100 GB/month | ~$9 |
| **TOTAL** | | **~$275/month** |

*Estimates based on AWS pricing as of March 2026. Actual costs vary with traffic.*

## Cost Allocation Tags

All resources are tagged with:

```hcl
Project     = "ecommerce"
Environment = "prod"          # dev/staging/prod → separate cost tracking
ManagedBy   = "terraform"
Owner       = "rizwan66"
CostCenter  = "engineering"
```

Use **AWS Cost Explorer** → Group by Tag → `Project` to see per-project spend.

## Optimization Strategies Applied

### 1. Reserved Instances / Savings Plans
**Estimated saving: 40–60%** on EC2 and RDS

Switch On-Demand EC2 and RDS to **1-year Compute Savings Plans**:
- EC2 3× t3.small: $45 → ~$27/month
- RDS Multi-AZ db.t3.medium: $50 → ~$30/month
- **Net saving: ~$38/month (~$456/year)**

### 2. Right-sized NAT Gateway (Shared)
**Estimated saving: ~$65/month**

Three NAT Gateways (one per AZ) cost ~$100/month. For non-prod environments:
- Use a **single NAT Gateway** (trade HA for cost in dev/staging)
- Or use **VPC Endpoints** for AWS services (S3, Secrets Manager, SSM) to eliminate NAT data charges
- For prod, keep 3 NAT GWs (HA requirement), but add S3 Gateway endpoint (free)

```hcl
# Add to vpc module for prod
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.us-east-1.s3"
  route_table_ids = concat(
    aws_route_table.private[*].id,
    aws_route_table.data[*].id
  )
}
```

### 3. Spot Instances for Non-Prod / Stateless Workers
**Estimated saving: 70% vs On-Demand**

For dev/staging ASGs, use a **mixed instances policy**:
```hcl
mixed_instances_policy {
  instances_distribution {
    on_demand_percentage_above_base_capacity = 0
    spot_allocation_strategy                 = "capacity-optimized"
  }
  launch_template { ... }
  overrides {
    instance_type = "t3.small"
    instance_type = "t3a.small"
    instance_type = "t2.small"
  }
}
```

### 4. Auto Scaling Schedule (Off-Peak)
**Estimated saving: ~30% on EC2**

Scale dev/staging down to 1 instance overnight:
```hcl
resource "aws_autoscaling_schedule" "scale_down_night" {
  scheduled_action_name  = "scale-down-night"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 1
  max_size               = 3
  desired_capacity       = 1
  recurrence             = "0 20 * * 1-5"  # 8pm weekdays
}
```

### 5. S3 Intelligent-Tiering for Logs
**Estimated saving: ~40% on log storage**

ALB logs and Config snapshots grow over time. Use Intelligent-Tiering:
```hcl
resource "aws_s3_bucket_intelligent_tiering_configuration" "logs" {
  bucket = aws_s3_bucket.alb_logs.id
  name   = "all-objects"
  status = "Enabled"
}
```

## Cost/Performance Trade-offs

| Decision | Cost Impact | Performance Impact | Rationale |
|----------|-----------|--------------------|-----------|
| Multi-AZ NAT (3×) | +$65/month | No cross-AZ NAT traffic | HA requirement for prod |
| RDS Multi-AZ | +$25/month | Automatic failover < 2min | Prod data durability |
| t3.small (burstable) | Lower than m-series | Good for web workloads | CPU bursting fits traffic patterns |
| ElastiCache Redis | +$25/month | -40ms per request (cache hit) | Cache-aside reduces DB load |
| gp3 storage (vs gp2) | Same price | +20% IOPS baseline | Free upgrade |

## FinOps Dashboard

A custom CloudWatch dashboard (`ecommerce-prod-dashboard`) tracks:
- Request rate (proxy for revenue activity)
- Instance count × instance type (direct EC2 cost driver)
- RDS connection count (right-sizing signal)
- NAT Gateway data processed (biggest variable cost)

Enable **AWS Cost Anomaly Detection** on the `ecommerce` project tag for automatic spend alerts.
