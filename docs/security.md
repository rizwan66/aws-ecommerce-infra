# Security Posture & Compliance

## Secrets Management

All secrets are stored in **AWS Secrets Manager** — zero hardcoded credentials anywhere in the codebase.

| Secret | Location | Rotation |
|--------|----------|----------|
| RDS master password | `Secrets Manager: ecommerce-prod/db-password` | Manual (enable auto-rotation for prod) |
| GitHub → AWS auth | OIDC (no static AWS keys) | N/A — token-based |

GitHub Actions accesses AWS via **OIDC federation** — the `AWS_ROLE_ARN` secret is an IAM role ARN, not an access key.

## IAM Roles & Least Privilege

### EC2 Instance Role
Allows only:
- `secretsmanager:GetSecretValue` on the specific DB secret ARN
- `cloudwatch:PutMetricData`, `logs:PutLogEvents` for observability
- `ec2:DescribeInstances` for instance metadata
- `s3:GetObject` on the artifacts bucket (scoped prefix)
- SSM Session Manager (replaces SSH bastion)
- CloudWatch Agent

### GitHub Actions Role
Assumes via OIDC, scoped to `repo:rizwan66/*`. Has broad infrastructure permissions for Terraform operations — tighten to specific resource ARNs in production.

## Network Security

| Control | Implementation |
|---------|----------------|
| Internet → App | Blocked. All traffic must pass through ALB |
| Internet → DB | Blocked. DB is in isolated data subnets |
| App → DB | Port 5432 only, from App SG only |
| App → Redis | Port 6379 only, from App SG only |
| EC2 IMDSv2 | Enforced (hop limit = 1, tokens required) |
| VPC Flow Logs | ALL traffic logged, 30-day retention |
| EBS Encryption | Enforced at launch template level |
| RDS Encryption | `storage_encrypted = true` |
| Redis Encryption | `at_rest_encryption_enabled` + `transit_encryption_enabled` |
| S3 Buckets | Public access fully blocked, SSE-S3 enforced |

## AWS Config Rules

Three compliance rules actively monitored:

1. **ENCRYPTED_VOLUMES** — All EBS volumes must be encrypted
2. **RDS_STORAGE_ENCRYPTED** — RDS instances must use storage encryption
3. **IAM_PASSWORD_POLICY** — IAM password policy meets minimum requirements

## Security Scanning in Pipeline

| Tool | What it checks | Stage |
|------|----------------|-------|
| tfsec | Terraform misconfigurations (hardcoded IPs, open SGs, etc.) | PR |
| checkov | 1000+ CIS/PCI/NIST policy checks against Terraform | PR |
| SARIF upload | Results visible in GitHub Security tab | PR |

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Credential leak | Low | Critical | Secrets Manager + OIDC, no static keys |
| DB breach | Low | High | Private subnets, SG isolation, encryption at rest |
| Instance compromise | Low | Medium | SSM-only access (no SSH), IMDSv2, least-privilege IAM |
| Data loss | Very Low | High | Multi-AZ RDS, 7-day backups, S3 versioning |
| DoS | Medium | Medium | ALB with rate limiting (configure WAF for prod) |
| Infrastructure drift | Low | Medium | Drift detection scheduled weekly |

## Compliance Mapping

| Control | CIS Benchmark | Implementation |
|---------|--------------|----------------|
| CIS 2.1.1 | S3 public access blocked | `aws_s3_bucket_public_access_block` |
| CIS 2.1.2 | S3 encryption | `aws_s3_bucket_server_side_encryption_configuration` |
| CIS 3.9 | VPC Flow Logs | `aws_flow_log` in VPC module |
| CIS 4.1 | No unrestricted SSH | No port 22 open anywhere |
| CIS 4.2 | No unrestricted RDP | No port 3389 open anywhere |
| CIS 5.2 | Default SGs restrict all | Not using default VPC SG |

## Security Testing Results

Run `tfsec ./terraform` and `checkov -d ./terraform` locally to reproduce.
Pipeline runs these on every PR with SARIF output uploaded to GitHub Security tab.
