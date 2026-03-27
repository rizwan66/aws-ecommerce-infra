# Disaster Recovery

## Recovery Objectives

| Tier | RTO | RPO | Strategy |
|------|-----|-----|----------|
| AZ failure | < 5 min | 0 | Multi-AZ: RDS auto-failover, ASG rebalances, NAT per AZ |
| Region failure | < 4 hr | < 15 min | Cross-region RDS read replica + manual promote |
| Data corruption | < 2 hr | < 24 hr | RDS automated daily snapshots (7-day retention) |

## AZ Failure (Primary DR Scenario)

The architecture is designed to withstand an AZ failure automatically:

1. **ALB**: Routes traffic to healthy AZs within 30 seconds
2. **ASG**: Detects unhealthy instances, launches replacements in surviving AZs
3. **RDS Multi-AZ**: Automatic failover to standby in ~1-2 minutes (DNS update)
4. **ElastiCache**: Automatic failover to replica node
5. **NAT Gateway**: Each AZ has its own — no cross-AZ dependency

**No manual intervention required for AZ failure.**

## Region Failure (Multi-Region DR)

### Setup

1. Enable **RDS cross-region read replica** in `us-west-2`:
```hcl
resource "aws_db_instance" "dr_replica" {
  provider               = aws.dr
  identifier             = "ecommerce-prod-dr-replica"
  replicate_source_db    = aws_db_instance.main.arn
  instance_class         = "db.t3.medium"
  storage_encrypted      = true
  publicly_accessible    = false
  skip_final_snapshot    = false
  vpc_security_group_ids = [module.security_dr.db_sg_id]
}
```

2. S3 bucket replication for artifacts:
```hcl
resource "aws_s3_bucket_replication_configuration" "artifacts" {
  role   = aws_iam_role.replication.arn
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "replicate-all"
    status = "Enabled"
    destination {
      bucket        = aws_s3_bucket.artifacts_dr.arn
      storage_class = "STANDARD"
    }
  }
}
```

### Failover Runbook

1. **Declare incident** — page on-call via SNS alert
2. **Promote RDS replica** in `us-west-2`:
   ```bash
   aws rds promote-read-replica \
     --db-instance-identifier ecommerce-prod-dr-replica \
     --region us-west-2
   ```
3. **Update Route53** health check → point to DR region ALB
4. **Scale up ASG** in DR region (normally kept at 0 or 1 warm instance)
5. **Verify** `/health` returns 200 in DR region
6. **Notify** stakeholders

### DR Region Terraform

A parallel Terraform workspace (`terraform workspace select dr`) deploys
the same modules to `us-west-2` with reduced scale (1 instance, no NAT HA)
to keep standby costs minimal (~$60/month warm).

## Backup & Restore

### Automated Backups
- RDS: Daily automated backup, 7-day retention, stored in S3 (AWS-managed)
- ElastiCache: Daily snapshot, 1-day retention
- Terraform state: S3 versioning enabled (can restore any state version)

### Manual Snapshot Restore
```bash
# Restore RDS from snapshot
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier ecommerce-prod-restored \
  --db-snapshot-identifier <snapshot-id> \
  --db-instance-class db.t3.medium \
  --no-publicly-accessible

# Verify restore
aws rds describe-db-instances \
  --db-instance-identifier ecommerce-prod-restored \
  --query 'DBInstances[0].DBInstanceStatus'
```

## Testing DR

Run the following quarterly:
1. **AZ Failure Simulation**: Terminate all instances in one AZ, verify app stays healthy
2. **RDS Failover Test**: Force failover via console, measure recovery time
3. **Snapshot Restore**: Restore DB from a 3-day-old snapshot to verify backup integrity
4. **Region Failover**: Promote DR replica and route traffic — target RTO < 4hr
