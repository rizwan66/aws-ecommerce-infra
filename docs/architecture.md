# Architecture Overview

## High-Level Design

```
Internet
   │
   ▼
┌─────────────────────────────────┐
│   Application Load Balancer     │  Public subnets (3 AZs)
│   (HTTP → HTTPS redirect)       │
└─────────────┬───────────────────┘
              │
   ┌──────────▼──────────┐
   │   Auto Scaling Group │  Private subnets (3 AZs)
   │   3+ EC2 instances   │  (no public IPs)
   │   (Amazon Linux 2023)│
   └──────┬──────┬────────┘
          │      │
    ┌─────▼─┐  ┌─▼──────────┐
    │  RDS   │  │ ElastiCache│  Data subnets (3 AZs)
    │ Multi- │  │  Redis 7.1 │
    │ AZ PG  │  │ (replicated│
    └────────┘  └────────────┘
```

## Network Tier Separation

| Tier    | Subnets      | Internet Access         | Security Group             |
|---------|-------------|-------------------------|----------------------------|
| Public  | 10.0.1-3.0/24 | IGW (direct)          | ALB SG (80/443 from 0.0.0.0/0) |
| App     | 10.0.11-13.0/24 | NAT Gateway         | App SG (8080 from ALB SG only) |
| Data    | 10.0.21-23.0/24 | NAT Gateway (egress)| DB SG (5432 from App SG only) |

## Components

### Compute
- **EC2 Auto Scaling Group**: Minimum 3 instances spread across 3 AZs
- **Launch Template**: IMDSv2 enforced, encrypted EBS, CloudWatch agent
- **Instance Refresh**: Rolling deployment with 66% minimum healthy
- **Scaling Policies**: CPU target tracking (70%) + ALB request count

### Database
- **RDS PostgreSQL 16**: Multi-AZ with automatic failover
- **Storage**: gp3 encrypted, auto-scaling, Performance Insights enabled
- **Backups**: 7-day retention, automated snapshots

### Caching
- **ElastiCache Redis 7.1**: 2-node replication group, in-transit encryption
- **Use case**: Session storage, cart data, product count cache

### Networking
- **VPC**: 3 public + 3 private + 3 data subnets across 3 AZs
- **NAT Gateways**: One per AZ to eliminate single points of failure
- **VPC Flow Logs**: All traffic logged to CloudWatch

### Security
- **IAM**: Least-privilege EC2 role, GitHub Actions OIDC (no static keys)
- **Secrets Manager**: DB credentials (no hardcoded secrets anywhere)
- **IMDSv2**: Enforced on all instances (SSRF mitigation)
- **AWS Config**: Continuous compliance monitoring with 3 managed rules
- **Security Groups**: Strict least-privilege rules between tiers

## Multi-AZ High Availability

- ALB spans all 3 public subnets
- ASG distributes instances across 3 private subnets
- RDS Multi-AZ: automatic failover < 2 minutes
- ElastiCache: automatic failover between nodes
- NAT Gateway: one per AZ (no cross-AZ dependency)

## CI/CD Flow

```
Developer
  │
  ▼ git push (feature branch)
GitHub PR
  │
  ├── terraform fmt -check
  ├── terraform validate
  ├── tflint
  ├── tfsec (security scan)
  ├── checkov (compliance)
  └── terraform plan (posted as PR comment)
  │
  ▼ Merge to main
  │
  ├── terraform apply (auto)
  └── ASG instance refresh (rolling)
```
