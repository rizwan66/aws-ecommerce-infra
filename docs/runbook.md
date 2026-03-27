# Operations Runbook

Day-2 operations guide for the AWS Ecommerce infrastructure.

---

## Table of Contents

- [Access & Authentication](#access--authentication)
- [Deployment Procedures](#deployment-procedures)
- [Incident Response](#incident-response)
- [Scaling Procedures](#scaling-procedures)
- [Database Operations](#database-operations)
- [Log Investigation](#log-investigation)
- [Infrastructure Changes](#infrastructure-changes)
- [Common Issues & Fixes](#common-issues--fixes)

---

## Access & Authentication

### AWS Console

Sign in via SSO or IAM user. Never use root account credentials.

### EC2 Instance Access (SSM — no SSH required)

```bash
# List running instances
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=ecommerce" "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,PrivateIpAddress,Placement.AvailabilityZone]' \
  --output table

# Start SSM session (no SSH, no bastion, no port 22)
aws ssm start-session --target i-1234567890abcdef0

# Run a command on all instances in the ASG
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups \
  --query "AutoScalingGroups[?contains(Tags[?Key=='Project'].Value,'ecommerce')].AutoScalingGroupName|[0]" \
  --output text)

INSTANCE_IDS=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query "AutoScalingGroups[0].Instances[*].InstanceId" \
  --output text)

aws ssm send-command \
  --instance-ids $INSTANCE_IDS \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl status ecommerce"]}' \
  --output text
```

### Terraform State

```bash
cd terraform

# See current state
terraform show

# List all resources
terraform state list

# Inspect a specific resource
terraform state show module.rds.aws_db_instance.main
```

---

## Deployment Procedures

### Standard Deploy (via GitOps)

```
1. Create feature branch
2. Make changes (Terraform or app code)
3. Open PR → CI runs automatically
4. Review plan output in PR comment
5. Get 1 approval
6. Merge to master → auto-apply
```

### Emergency Deploy (manual)

```bash
cd terraform
terraform init
terraform plan -var="alert_email=alerts@example.com" -out=emergency.tfplan
terraform apply emergency.tfplan
```

**Always prefer GitOps.** Manual deploys bypass peer review and security scans.

### Rollback Infrastructure

```bash
# Option 1: Revert the Git commit and let CI re-apply
git revert HEAD
git push origin master

# Option 2: Restore from previous state version (S3 versioned)
aws s3api list-object-versions \
  --bucket rizwan66-terraform-state \
  --prefix aws-ecommerce/terraform.tfstate \
  --query 'Versions[*].[VersionId,LastModified]' \
  --output table

# Download specific state version
aws s3api get-object \
  --bucket rizwan66-terraform-state \
  --key aws-ecommerce/terraform.tfstate \
  --version-id <version-id> \
  terraform.tfstate.backup
```

### Rollback Application

```bash
# Option 1: Trigger instance refresh with previous artifact
# Update S3 artifacts to previous version, then trigger refresh

# Option 2: Find previous healthy instance and snapshot its config
# The ASG will launch new instances from the current launch template
# Pin the launch template version to a previous known-good version

aws ec2 describe-launch-template-versions \
  --launch-template-name "ecommerce-prod-app-lt" \
  --query 'LaunchTemplateVersions[*].[VersionNumber,CreateTime]' \
  --output table

# Update ASG to use specific (older) launch template version
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "ecommerce-prod-app-asg" \
  --launch-template "LaunchTemplateName=ecommerce-prod-app-lt,Version=5"

# Trigger refresh with old version
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "ecommerce-prod-app-asg" \
  --preferences '{"MinHealthyPercentage": 66}'
```

---

## Incident Response

### Flowchart

```
Alert fires (CloudWatch → SNS → Email)
        │
        ▼
Identify affected resource:
  - ALB 5xx → app errors (check app logs)
  - CPU high → resource exhaustion (check process list)
  - Unhealthy hosts → instance failure (check EC2 health)
  - RDS CPU → slow queries (check Performance Insights)
  - RDS storage → disk full (check table sizes)
        │
        ▼
Contain: Is the issue expanding?
  - Scale out (add capacity)
  - Fail over (shift traffic)
  - Isolate (remove bad instance from ALB)
        │
        ▼
Diagnose: Root cause
        │
        ▼
Remediate: Fix + deploy
        │
        ▼
Post-mortem: Document + prevent recurrence
```

### High 5xx Error Rate

```bash
# 1. Check CloudWatch Logs for app errors
aws logs filter-log-events \
  --log-group-name "/aws/ec2/ecommerce/prod/app" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '30 minutes ago' +%s000) \
  --query 'events[*].[timestamp,message]' \
  --output table

# 2. Check ALB access logs in S3
# Logs are in: s3://ecommerce-prod-alb-logs-{account}/alb/AWSLogs/...
# Use Athena for querying at scale

# 3. Check specific instance
aws ssm start-session --target i-INSTANCE_ID
$ journalctl -u ecommerce -n 100 --no-pager
$ systemctl status ecommerce

# 4. Restart app on all instances (last resort)
aws ssm send-command \
  --instance-ids $INSTANCE_IDS \
  --document-name "AWS-RunShellScript" \
  --parameters '{"commands":["systemctl restart ecommerce"]}'
```

### Instance Unhealthy / Not Passing Health Checks

```bash
# 1. Check health check target specifically
curl http://<private-ip>:8080/health

# Expected response:
# {
#   "status": "healthy",
#   "instance_id": "i-...",
#   "availability_zone": "us-east-1a",
#   "dependencies": {
#     "database": {"status": "healthy"},
#     "cache": {"status": "healthy"}
#   }
# }

# 2. If database is unhealthy, check RDS
aws rds describe-db-instances \
  --db-instance-identifier "ecommerce-prod-db" \
  --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address]'

# 3. If RDS is failing over, check event log
aws rds describe-events \
  --source-identifier "ecommerce-prod-db" \
  --duration 60  # last 60 minutes

# 4. Force deregister unhealthy instance (let ASG replace it)
aws elbv2 deregister-targets \
  --target-group-arn <TG_ARN> \
  --targets Id=i-INSTANCE_ID
```

### RDS Failover

```bash
# Force failover (for testing or if primary is degraded)
aws rds reboot-db-instance \
  --db-instance-identifier "ecommerce-prod-db" \
  --force-failover

# Monitor failover progress (polls every 10s)
watch -n 10 'aws rds describe-db-instances \
  --db-instance-identifier ecommerce-prod-db \
  --query "DBInstances[0].[DBInstanceStatus,MultiAZ,Endpoint.Address]" \
  --output table'

# Expected timeline:
# 0s:   DBInstanceStatus = rebooting
# 60s:  DBInstanceStatus = modifying (DNS update)
# 120s: DBInstanceStatus = available (new primary)
```

---

## Scaling Procedures

### Manual Scale Out (emergency)

```bash
# Immediately add instances (bypass scaling policy delay)
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "ecommerce-prod-app-asg" \
  --desired-capacity 6
```

### Adjust Scaling Limits

```bash
# Increase max if consistently hitting ceiling
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "ecommerce-prod-app-asg" \
  --max-size 12
```

**Always update `terraform/variables.tf` after manual changes to prevent drift.**

### Scheduled Scaling (off-peak)

```bash
# Scale down at night (saves ~30% on EC2 cost)
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name "ecommerce-prod-app-asg" \
  --scheduled-action-name "scale-down-night" \
  --recurrence "0 20 * * 1-5" \
  --min-size 1 --max-size 3 --desired-capacity 1

# Scale back up in morning
aws autoscaling put-scheduled-update-group-action \
  --auto-scaling-group-name "ecommerce-prod-app-asg" \
  --scheduled-action-name "scale-up-morning" \
  --recurrence "0 8 * * 1-5" \
  --min-size 3 --max-size 9 --desired-capacity 3
```

---

## Database Operations

### Connect to RDS (via SSM + psql)

```bash
# Get RDS endpoint
RDS_ENDPOINT=$(terraform output -raw rds_endpoint)

# Start SSM session on an app instance
aws ssm start-session --target i-INSTANCE_ID

# On the instance (psql is available if installed):
$ DB_PASS=$(aws secretsmanager get-secret-value \
    --secret-id ecommerce-prod/db-password \
    --query SecretString --output text)
$ PGPASSWORD="$DB_PASS" psql -h $RDS_ENDPOINT -U dbadmin -d ecommercedb
```

### Manual Snapshot

```bash
aws rds create-db-snapshot \
  --db-instance-identifier "ecommerce-prod-db" \
  --db-snapshot-identifier "ecommerce-prod-manual-$(date +%Y%m%d-%H%M)"
```

### Restore from Snapshot

```bash
# 1. Create new instance from snapshot
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier "ecommerce-prod-restored" \
  --db-snapshot-identifier <snapshot-id> \
  --db-instance-class db.t3.medium \
  --db-subnet-group-name ecommerce-prod-db-subnet-group \
  --vpc-security-group-ids <db-sg-id> \
  --no-publicly-accessible

# 2. Wait for restore to complete
aws rds wait db-instance-available \
  --db-instance-identifier "ecommerce-prod-restored"

# 3. Update app config to point to restored instance
# (Update Terraform variable + re-apply, or update SSM parameter)
```

---

## Log Investigation

### Application Logs

```bash
# Tail live logs (replace LOG_STREAM with instance ID)
aws logs tail "/aws/ec2/ecommerce/prod/app" --follow

# Search for errors in last hour
aws logs filter-log-events \
  --log-group-name "/aws/ec2/ecommerce/prod/app" \
  --filter-pattern "ERROR" \
  --start-time $(date -d '1 hour ago' +%s000)

# Search for specific request
aws logs filter-log-events \
  --log-group-name "/aws/ec2/ecommerce/prod/app" \
  --filter-pattern '"POST /api/cart"'
```

### VPC Flow Logs

```bash
# Search for rejected traffic to DB port
aws logs filter-log-events \
  --log-group-name "/aws/vpc/ecommerce-prod-flow-logs" \
  --filter-pattern "[v, a, id, b, c, d, srcport, dstport=5432, ...]"

# Find what's hitting the DB from unexpected sources
aws logs filter-log-events \
  --log-group-name "/aws/vpc/ecommerce-prod-flow-logs" \
  --filter-pattern "[version, accountid, interfaceid, srcaddr, dstaddr, srcport, dstport=5432, protocol, packets, bytes, start, end, action=REJECT, logstatus]"
```

---

## Infrastructure Changes

### Adding a New Resource

1. Add Terraform code to the appropriate module (or create a new one)
2. Add necessary variables and outputs
3. Open PR — CI runs fmt + validate + tflint + tfsec + plan
4. Review the plan diff carefully in the PR comment
5. Get approval → merge → auto-apply

### Destroying a Resource

```bash
# Target-destroy a single resource (careful!)
terraform destroy -target=module.monitoring.aws_cloudwatch_metric_alarm.rds_cpu_high

# Full destroy (non-prod only)
terraform destroy -var="environment=dev"
```

**Never run `terraform destroy` in production without explicit sign-off.**

### Importing Existing Resources

```bash
# If a resource was created manually and needs to be brought under Terraform
terraform import module.vpc.aws_internet_gateway.main igw-12345678
```

---

## Common Issues & Fixes

### "Error: Error acquiring the state lock"

```
Error: Error locking state: Error acquiring the state lock
```

**Cause:** A previous Terraform run crashed without releasing the lock.

```bash
# View lock info
aws dynamodb get-item \
  --table-name rizwan66-terraform-locks \
  --key '{"LockID": {"S": "rizwan66-terraform-state/aws-ecommerce/terraform.tfstate"}}'

# Force-unlock (only if you're sure no run is active)
terraform force-unlock <LOCK_ID>
```

### "Error: Provider produced inconsistent final plan"

**Cause:** Usually a timing issue or dependency race condition.

```bash
# Re-run plan — usually resolves on second attempt
terraform plan -out=tfplan
terraform apply tfplan
```

### App shows "unhealthy" for DB

**Cause:** EC2 instance cannot reach RDS endpoint.

```bash
# Verify security group allows app → DB on 5432
aws ec2 describe-security-groups \
  --group-ids <db-sg-id> \
  --query 'SecurityGroups[0].IpPermissions'

# Verify RDS is available
aws rds describe-db-instances \
  --db-instance-identifier ecommerce-prod-db \
  --query 'DBInstances[0].DBInstanceStatus'

# Verify secret has correct endpoint
aws secretsmanager get-secret-value \
  --secret-id ecommerce-prod/db-password \
  --query 'SecretString'
```

### Instances not launching (ASG stuck)

```bash
# Check ASG activity log
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "ecommerce-prod-app-asg" \
  --query 'Activities[0:5].[StatusCode,StatusMessage,Description]' \
  --output table

# Common causes:
# - AMI not found (check data.aws_ami filter)
# - IAM instance profile missing
# - Security group ID invalid after VPC recreate
# - Subnet capacity exhausted in an AZ
```

### NAT Gateway throttled / high latency

```bash
# Check NAT Gateway byte count
aws cloudwatch get-metric-statistics \
  --namespace AWS/NatGateway \
  --metric-name BytesOutToDestination \
  --dimensions Name=NatGatewayId,Value=<nat-gw-id> \
  --start-time $(date -d '1 hour ago' --iso-8601=seconds) \
  --end-time $(date --iso-8601=seconds) \
  --period 300 \
  --statistics Sum

# If high: consider adding VPC Interface Endpoints for AWS services
# (S3, Secrets Manager, SSM) to reduce NAT traffic cost and latency
```
