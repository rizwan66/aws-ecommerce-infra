# AWS Ecommerce Infrastructure

Production-grade AWS infrastructure for a multi-tier ecommerce application, built with Terraform and deployed via GitHub Actions.

## Architecture

- **3-tier network**: Public (ALB) → Private (EC2 ASG) → Data (RDS + Redis)
- **Multi-AZ**: All tiers span 3 Availability Zones
- **3+ EC2 instances** behind an Application Load Balancer
- **RDS PostgreSQL 16** Multi-AZ with Performance Insights
- **ElastiCache Redis 7.1** with replication and encryption
- **Zero hardcoded secrets** — all via AWS Secrets Manager
- **GitHub Actions OIDC** — no static AWS keys

See [docs/architecture.md](docs/architecture.md) for the full architecture diagram.

## Project Structure

```
.
├── terraform/
│   ├── main.tf              # Root module — assembles all modules
│   ├── variables.tf         # Input variables
│   ├── outputs.tf           # Outputs
│   ├── versions.tf          # Provider/version constraints
│   ├── backend.tf           # S3 remote state configuration
│   └── modules/
│       ├── vpc/             # VPC, subnets, NAT GW, flow logs
│       ├── alb/             # Application Load Balancer + target group
│       ├── ec2/             # Launch template + Auto Scaling Group
│       ├── rds/             # PostgreSQL Multi-AZ instance
│       ├── elasticache/     # Redis replication group
│       ├── iam/             # EC2 role + GitHub Actions OIDC role
│       ├── security/        # Security groups (least privilege)
│       └── monitoring/      # CloudWatch dashboard + 5 alarms + AWS Config
├── app/
│   ├── app.py               # Flask ecommerce app
│   ├── requirements.txt
│   ├── Dockerfile
│   └── templates/index.html # UI displaying instance ID, AZ, health status
├── .github/workflows/
│   ├── terraform.yml        # Terraform lint → scan → plan → apply
│   └── app-deploy.yml       # App test → build → ASG rolling deploy
├── tests/terratest/
│   └── vpc_test.go          # Terratest VPC validation
├── scripts/
│   ├── setup-backend.sh     # Bootstrap S3 state bucket + DynamoDB lock table
│   └── drift-detection.sh   # Detect infrastructure drift
└── docs/
    ├── architecture.md
    ├── security.md
    ├── cost-optimization.md
    └── disaster-recovery.md
```

## Requirements Coverage

| Requirement | Implementation |
|-------------|---------------|
| Terraform IaC (modular) | 7 reusable modules in `terraform/modules/` |
| Remote state | S3 + DynamoDB lock (`backend.tf`) |
| Variables & outputs | `variables.tf`, `outputs.tf` in root + each module |
| Multi-AZ VPC | 3 public + 3 private + 3 data subnets across 3 AZs |
| NAT Gateway (private egress) | One per AZ for HA |
| Least-privilege security groups | 4 SGs with strict tier-to-tier rules |
| Load-balanced 3+ instances | ALB + ASG (min=3, spanning 3 AZs) |
| Health checks | ALB health check on `/health` |
| Python ecommerce app | Flask app with instance ID, AZ, health status |
| `/health` endpoint | Returns JSON with DB/Redis dependency status |
| Database | RDS PostgreSQL Multi-AZ |
| Cache | ElastiCache Redis replicated cluster |
| GitHub Actions CI/CD | `terraform.yml` + `app-deploy.yml` |
| Terraform validation in pipeline | fmt + validate + tflint |
| Security scanning | tfsec + checkov with SARIF output |
| Deploy on merge to main | `apply` job gated on main branch |
| Drift detection | `drift-detection` job + `scripts/drift-detection.sh` |
| CloudWatch monitoring | Dashboard + 5 alarms (5xx, CPU, unhealthy hosts, RDS CPU, RDS storage) |
| Log aggregation | CloudWatch Logs (app + VPC flow logs + ALB access logs) |
| Alerting (3+ alerts) | 5 CloudWatch alarms → SNS → email |
| AWS Config compliance | 3 managed rules (encrypted volumes, RDS encrypted, IAM password policy) |
| Security scanning in pipeline | tfsec + checkov |
| Secrets management | Secrets Manager for DB password, OIDC for CI/CD |
| IAM least privilege | Scoped EC2 role + OIDC GitHub Actions role |
| Cost allocation tags | 5 tags on all resources via provider `default_tags` |
| Cost projection | See `docs/cost-optimization.md` (~$275/month) |
| 3+ optimization strategies | Savings Plans, Spot instances, VPC endpoints, scheduled scaling, S3 Intelligent-Tiering |
| Disaster recovery | Multi-AZ (automatic) + cross-region runbook in `docs/disaster-recovery.md` |
| Infrastructure testing | Terratest suite in `tests/terratest/` |

## Quick Start

### 1. Bootstrap Remote State

```bash
# Creates S3 bucket + DynamoDB lock table
./scripts/setup-backend.sh us-east-1
```

### 2. Set GitHub Secrets

In your GitHub repo settings, add:

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | ARN of the GitHub Actions IAM role |
| `ALERT_EMAIL` | Email address for CloudWatch alerts |

### 3. Deploy via GitOps

```bash
# Push to main → GitHub Actions runs terraform plan + apply automatically
git push origin main
```

### 4. Manual Deployment

```bash
cd terraform
terraform init
terraform plan -var="alert_email=you@example.com" -out=tfplan
terraform apply tfplan
```

### 5. Access the Application

```bash
# Get ALB DNS name
terraform output alb_dns_name
# → ecommerce-prod-alb-XXXXXX.us-east-1.elb.amazonaws.com
```

Visit `http://<alb_dns_name>:8080` — the app displays:
- Instance ID & Availability Zone
- Database and Redis health status
- Product catalogue with cart functionality
- `/health` endpoint for ALB health checks

## Monitoring

The CloudWatch dashboard is available at the URL from:
```bash
terraform output cloudwatch_dashboard_url
```

Configured alarms:
1. **ALB 5xx errors** > 10/minute
2. **ASG CPU** > 85% for 3 minutes
3. **Unhealthy hosts** > 0
4. **RDS CPU** > 80% for 3 minutes
5. **RDS free storage** < 5 GB

## Security

See [docs/security.md](docs/security.md) for the full security posture documentation.

Key controls:
- No hardcoded secrets anywhere in the codebase
- IMDSv2 enforced on all EC2 instances
- All data encrypted at rest and in transit
- VPC Flow Logs enabled
- AWS Config continuously monitoring compliance

## Cost

Estimated: **~$275/month** (us-east-1, prod, On-Demand pricing)
With 1-year Savings Plans: **~$200/month**

See [docs/cost-optimization.md](docs/cost-optimization.md) for detailed breakdown and optimization strategies.

---

Infrastructure managed by Terraform | CI/CD via GitHub Actions | Owner: rizwan66
