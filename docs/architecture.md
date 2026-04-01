# Architecture Documentation

Full technical architecture with diagrams, design rationale, and component explanations.

---

## System Context

```mermaid
graph TB
    subgraph Users["External Users"]
        U1[🌐 Browser / Mobile]
        U2[📱 API Client]
    end

    subgraph CI["CI/CD System"]
        GH[GitHub Actions\nTerraform + App Deploy]
        DEV[👨‍💻 Developer\ngit push / PR]
    end

    subgraph AWS["AWS Cloud"]
        INFRA[AWS Ecommerce\nInfrastructure]
    end

    subgraph Ops["Operations"]
        ONCALL[👷 On-Call Engineer\nSSM Session Manager]
        EMAIL[📧 Alert Email\nCloudWatch → SNS]
    end

    U1 -->|HTTPS| INFRA
    U2 -->|HTTPS API| INFRA
    DEV -->|git push| GH
    GH -->|terraform apply + ASG refresh| INFRA
    INFRA -->|CloudWatch alarm| EMAIL
    EMAIL -->|notification| ONCALL
    ONCALL -->|SSM session| INFRA
```

---

## Network Architecture

```mermaid
graph TB
    subgraph Internet["Internet"]
        INT((Internet))
    end

    subgraph VPC["VPC — 10.0.0.0/16"]
        IGW[Internet Gateway]

        subgraph Public["Public Tier"]
            subgraph AZ_A_PUB["us-east-1a — 10.0.1.0/24"]
                ALB_A[ALB Node]
                NAT_A[NAT Gateway\nEIP: x.x.x.1]
            end
            subgraph AZ_B_PUB["us-east-1b — 10.0.2.0/24"]
                ALB_B[ALB Node]
                NAT_B[NAT Gateway\nEIP: x.x.x.2]
            end
            subgraph AZ_C_PUB["us-east-1c — 10.0.3.0/24"]
                ALB_C[ALB Node]
                NAT_C[NAT Gateway\nEIP: x.x.x.3]
            end
        end

        subgraph App["Application Tier (No Public IP)"]
            subgraph AZ_A_APP["us-east-1a — 10.0.11.0/24"]
                EC2_A[EC2: t3.small\nPort 8080]
            end
            subgraph AZ_B_APP["us-east-1b — 10.0.12.0/24"]
                EC2_B[EC2: t3.small\nPort 8080]
            end
            subgraph AZ_C_APP["us-east-1c — 10.0.13.0/24"]
                EC2_C[EC2: t3.small\nPort 8080]
            end
        end

        subgraph Data["Data Tier (Isolated)"]
            subgraph AZ_A_DAT["us-east-1a — 10.0.21.0/24"]
                RDS_P[(RDS Primary\nPort 5432)]
                REDIS_P[(Redis Primary\nPort 6379)]
            end
            subgraph AZ_B_DAT["us-east-1b — 10.0.22.0/24"]
                RDS_S[(RDS Standby\nAuto-failover)]
                REDIS_R[(Redis Replica\nAuto-failover)]
            end
        end

        subgraph RouteTable["Route Tables"]
            RT_PUB[Public RT\n0.0.0.0/0 → IGW]
            RT_A[Private RT A\n0.0.0.0/0 → NAT-A]
            RT_B[Private RT B\n0.0.0.0/0 → NAT-B]
            RT_C[Private RT C\n0.0.0.0/0 → NAT-C]
        end
    end

    INT --> IGW
    IGW --> ALB_A & ALB_B & ALB_C
    ALB_A --> EC2_A
    ALB_B --> EC2_B
    ALB_C --> EC2_C
    EC2_A --> RDS_P & REDIS_P
    EC2_B --> RDS_P & REDIS_P
    EC2_C --> RDS_P & REDIS_P
    RDS_P -.->|sync| RDS_S
    REDIS_P -.->|async| REDIS_R
    EC2_A -.->|pkg updates\nAWS APIs| NAT_A --> IGW
    EC2_B -.->|pkg updates\nAWS APIs| NAT_B --> IGW
    EC2_C -.->|pkg updates\nAWS APIs| NAT_C --> IGW

    style Public fill:#dbeafe,stroke:#2563eb
    style App fill:#dcfce7,stroke:#16a34a
    style Data fill:#fef9c3,stroke:#ca8a04
```

---

## Security Group Rules

```mermaid
graph LR
    subgraph SGs["Security Groups"]
        direction TB
        INTERNET["0.0.0.0/0\n(Internet)"]

        ALB_SG["ALB-SG\n─────────\nIngress:\n• 80  ← 0.0.0.0/0\n• 443 ← 0.0.0.0/0\nEgress: all"]

        APP_SG["App-SG\n─────────\nIngress:\n• 8080 ← ALB-SG only\nEgress: all\n(NAT → internet)"]

        DB_SG["DB-SG\n─────────\nIngress:\n• 5432 ← App-SG only\nEgress: all"]

        CACHE_SG["Cache-SG\n─────────\nIngress:\n• 6379 ← App-SG only\nEgress: all"]
    end

    INTERNET -->|80, 443| ALB_SG
    ALB_SG -->|8080 only| APP_SG
    APP_SG -->|5432 only| DB_SG
    APP_SG -->|6379 only| CACHE_SG

    style INTERNET fill:#fecaca
    style ALB_SG fill:#bfdbfe
    style APP_SG fill:#bbf7d0
    style DB_SG fill:#fde68a
    style CACHE_SG fill:#e9d5ff
```

**Key security property:** There is no direct path from the internet to the database or cache. Traffic must traverse both the ALB (TLS termination) and the EC2 application tier.

---

## IAM Permission Model

```mermaid
graph TB
    subgraph GitHub["GitHub Actions (OIDC)"]
        GH_WF[Workflow Token - token.actions.githubusercontent.com]
    end

    subgraph IAM["IAM"]
        OIDC[OIDC Identity Provider\ntoken.actions.githubusercontent.com]
        GH_ROLE[GitHub Actions Role\nAssume via OIDC\nscoped to: repo:rizwan66/*]
        EC2_ROLE[EC2 Instance Role\nLeast-privilege]
        EC2_PROFILE[Instance Profile\nAttached to launch template]
    end

    subgraph AWS_SVC["AWS Services"]
        SM[Secrets Manager\ndb-password]
        CW[CloudWatch\nMetrics + Logs]
        SSM_SVC[SSM\nSession Manager]
        S3[S3\nArtifacts bucket]
        EC2_SVC[EC2\nDescribe only]
        TF_RESOURCES[All Terraform\nManaged Resources]
    end

    GH_WF -->|AssumeRoleWithWebIdentity| OIDC
    OIDC --> GH_ROLE
    GH_ROLE -->|Full IaC permissions| TF_RESOURCES
    EC2_ROLE -->|GetSecretValue - this ARN only| SM
    EC2_ROLE -->|PutMetricData + PutLogEvents| CW
    EC2_ROLE -->|Session Manager| SSM_SVC
    EC2_ROLE -->|GetObject - artifacts prefix| S3
    EC2_ROLE -->|DescribeInstances| EC2_SVC
    EC2_ROLE --> EC2_PROFILE

    style GH_ROLE fill:#a78bfa
    style EC2_ROLE fill:#34d399
    style SM fill:#f87171
```

---

## Application Request Flow (Detailed)

```mermaid
sequenceDiagram
    autonumber
    actor User as User / Browser
    participant DNS as Route53 / DNS
    participant ALB as ALB (us-east-1)
    participant EC2 as EC2 Instance (AZ-A)
    participant Redis as Redis Primary
    participant RDS as RDS Primary
    participant CW as CloudWatch

    User->>DNS: Resolve ecommerce.example.com
    DNS-->>User: ALB IP (anycast)

    User->>ALB: GET / HTTP/1.1
    ALB-->>User: 301 → https://

    User->>ALB: GET / HTTPS
    Note over ALB: TLS termination\nSelect healthy target (Round Robin)
    ALB->>EC2: GET / HTTP/1.1 Port 8080\nX-Forwarded-For: user-ip

    Note over EC2: Cache-aside pattern
    EC2->>Redis: GET product_count
    alt Cache HIT (TTL: 60s)
        Redis-->>EC2: "6"
    else Cache MISS
        Redis-->>EC2: nil
        EC2->>RDS: SELECT count(*) FROM products
        RDS-->>EC2: 6 rows
        EC2->>Redis: SETEX product_count 60 "6"
    end

    EC2-->>ALB: 200 OK\nHTML with instance_id, AZ, products

    ALB-->>User: 200 OK (response)

    Note over EC2,CW: Async (every 60s)
    EC2->>CW: PutMetricData(CPU, mem, disk)
    EC2->>CW: PutLogEvents(request log)

    Note over ALB,CW: ALB publishes metrics every 1min
    ALB->>CW: RequestCount, TargetResponseTime, 5xxCount
```

---

## Auto Scaling Decision Tree

```mermaid
flowchart TD
    M1[CloudWatch\nCollects metrics\nevery 60s]

    M1 --> C1{ASG Avg CPU\n> 70%?}
    M1 --> C2{ALB Requests/target\n> 1000/min?}

    C1 -->|Yes, 3+ minutes| SO1[Scale Out\nAdd instances\nup to max=9]
    C1 -->|No, cooldown| SI1[Scale In\nRemove instances\nkeep min=3]

    C2 -->|Yes| SO2[Scale Out\nAlgorithm: target tracking\nautomatic]
    C2 -->|No| SI2[Scale In\nWait for cooldown period]

    SO1 & SO2 --> LAUNCH[Launch new instance\nfrom Launch Template]
    LAUNCH --> UD[Run user_data\nInstall app ~90s]
    UD --> HC[ALB Health Check\nGET /health every 30s]
    HC -->|200 OK × 2| REG[Register to target group\nStart receiving traffic]
    HC -->|Fail × 3| TERM[Terminate\nLaunch replacement]

    REG --> SERVE[Serve traffic]
    SI1 & SI2 --> DRAIN[Deregister from ALB\nDrain connections 30s]
    DRAIN --> KILL[Terminate instance]

    style SO1 fill:#bbf7d0
    style SO2 fill:#bbf7d0
    style SI1 fill:#fecaca
    style SI2 fill:#fecaca
    style TERM fill:#fecaca
```

---

## Data Flow: Secrets Management

```mermaid
sequenceDiagram
    participant TF as Terraform\n(apply time)
    participant RP as random_password
    participant SM as Secrets Manager
    participant RDS as RDS Instance
    participant EC2 as EC2 User Data\n(boot time)
    participant APP as Flask App

    Note over TF,SM: Apply time (infrastructure creation)
    TF->>RP: generate 24-char password
    RP-->>TF: "X9!abc..."
    TF->>SM: CreateSecret(name=ecommerce-prod/db-password)
    SM-->>TF: secret ARN
    TF->>SM: PutSecretValue(secret="X9!abc...")
    TF->>RDS: CreateDBInstance(password="X9!abc...")

    Note over EC2,APP: Boot time (instance launch)
    EC2->>EC2: IMDSv2 token request
    EC2->>SM: GetSecretValue(secret_arn)\n[uses IAM role, no static keys]
    SM-->>EC2: "X9!abc..."
    EC2->>EC2: Write to /opt/ecommerce/config.py
    EC2->>APP: systemctl start ecommerce
    APP->>RDS: Connect(host=endpoint, pass="X9!abc...")

    Note over TF,APP: Secret never in: Git, env vars, logs, CLI history
```

---

## High Availability Failure Scenarios

```mermaid
graph TB
    subgraph Normal["Normal Operation"]
        U1([User]) --> ALB1[ALB]
        ALB1 --> EC2_1[EC2 AZ-A]
        ALB1 --> EC2_2[EC2 AZ-B]
        ALB1 --> EC2_3[EC2 AZ-C]
        EC2_1 & EC2_2 & EC2_3 --> RDS_P1[(RDS Primary)]
        RDS_P1 -.->|sync| RDS_S1[(RDS Standby)]
    end

    subgraph AZ_Fail["AZ-A Failure (Auto-recovered)"]
        U2([User]) --> ALB2[ALB\nroutes around AZ-A]
        ALB2 --> EC2_4[EC2 AZ-B ✓]
        ALB2 --> EC2_5[EC2 AZ-C ✓]
        EC2_X[EC2 AZ-A ✗] -.->|unhealthy| ALB2
        EC2_4 & EC2_5 --> RDS_P2[(RDS Primary AZ-B)]
        Note_1[ASG launches\nreplacement in\nAZ-B or AZ-C]
    end

    subgraph RDS_Fail["RDS Primary Failure (Auto-recovered ~2min)"]
        U3([User]) --> ALB3[ALB]
        ALB3 --> EC2_6[EC2 Instances]
        EC2_6 -.->|connection error\nretry logic| RDS_X[(Primary ✗)]
        RDS_X -.->|failover\nDNS update| RDS_N[(New Primary\nfrom standby)]
        EC2_6 --> RDS_N
    end

    style EC2_X fill:#fecaca
    style RDS_X fill:#fecaca
    style Note_1 fill:#fef9c3
```

---

## Monitoring Architecture

```mermaid
graph TB
    subgraph Sources["Metric Sources"]
        ALB_M[ALB Metrics\nRequestCount\nResponseTime\n5xx errors]
        ASG_M[ASG Metrics\nInstance count\nCPU utilization]
        RDS_M[RDS Metrics\nCPU, Connections\nFreeStorage]
        APP_M[App Metrics\nCustom via CW Agent\nCPU, mem, disk]
        LOG_M[Logs\nApp logs\nVPC Flow Logs\nALB Access Logs]
    end

    subgraph CW["CloudWatch"]
        DASH[Dashboard\n8 widgets]
        ALARMS[5 Alarms\nEvaluate continuously]
        CW_LOGS[Log Groups\nRetention 14-30 days]
    end

    subgraph Config["AWS Config"]
        REC[Configuration Recorder\nAll resources]
        RULES[3 Compliance Rules\nEncryption, IAM policy]
        S3_CFG[S3 Snapshot Bucket\nEncrypted]
    end

    subgraph Notification["Alerting"]
        SNS[SNS Topic]
        EMAIL[Email\nalerts@example.com]
    end

    ALB_M & ASG_M & RDS_M & APP_M --> CW
    LOG_M --> CW_LOGS
    ALARMS -->|threshold breach| SNS
    ALARMS -->|recovery| SNS
    SNS --> EMAIL
    REC --> RULES
    REC --> S3_CFG
    CW --> DASH

    style ALARMS fill:#fde68a
    style SNS fill:#f87171
    style EMAIL fill:#f87171
```

---

## CI/CD Pipeline Flow

```mermaid
flowchart TD
    subgraph PR["Pull Request Checks"]
        FMT[terraform fmt -check]
        VAL[terraform validate]
        LINT[tflint]
        SEC[tfsec + checkov]
        PLAN[terraform plan\nPost as PR comment]
    end

    subgraph Deploy["Deploy on Merge to main"]
        APPLY[terraform apply\nfrom saved tfplan]
        APP_TEST[pytest + flake8]
        BUILD[docker build + push ECR]
        REFRESH[ASG Instance Refresh\n66% min healthy]
    end

    subgraph Schedule["Scheduled (Weekly)"]
        DRIFT[Drift Detection\nterraform plan --detailed-exitcode]
    end

    DEV([Developer]) -->|git push branch| PR
    FMT & VAL & LINT --> PLAN
    SEC -->|SARIF| GH_SEC[GitHub\nSecurity Tab]
    PLAN -->|PR comment| REV{Code Review\n1 approval}
    REV -->|Approved| MERGE([Merge to main])
    MERGE --> APPLY & APP_TEST
    APP_TEST -->|pass| BUILD
    BUILD --> REFRESH
    REFRESH -->|success| DONE([Deploy Complete])
    REFRESH -->|fail| ROLLBACK[Old instances\nkeep serving]
    DRIFT -->|exit 2| ALERT([Alert: Drift Detected])

    style DONE fill:#bbf7d0
    style ROLLBACK fill:#fde68a
    style ALERT fill:#fecaca
```

---

## Component Sizing (Production)

| Component | Configuration | Purpose |
|-----------|--------------|---------|
| VPC | /16 (65,536 IPs) | Room for growth |
| Public subnets | /24 each × 3 | 254 IPs per AZ (ALB + future) |
| Private subnets | /24 each × 3 | 254 IPs per AZ (EC2 fleet) |
| Data subnets | /24 each × 3 | 254 IPs per AZ (DB + cache) |
| EC2 instances | t3.small (2 vCPU, 2GB) | Burstable; web/API workload |
| ASG | min=3, desired=3, max=9 | 3× scale headroom |
| RDS | db.t3.medium (2 vCPU, 4GB) | Burstable; OLTP workload |
| RDS storage | 20GB gp3, auto-scale to 40GB | Consistent 3000 IOPS |
| ElastiCache | cache.t3.micro × 2 | Session + cache data |
| Redis max memory | LRU eviction policy | Cache workload optimized |

---

## Technology Decisions

| Decision | Alternative Considered | Rationale |
|----------|----------------------|-----------|
| Terraform (HCL) | CDK, Pulumi | Industry standard; most cloud job postings |
| S3 + DynamoDB state | Terraform Cloud | No external service dependency; free |
| GitHub Actions | Jenkins, CircleCI | Native to GitHub; OIDC support |
| Flask | FastAPI, Django | Minimal; easy to understand; focus on infra |
| PostgreSQL 16 | MySQL, Aurora | Open standard; `psycopg2` widely used |
| Redis 7.1 | Memcached, DynamoDB | Supports data structures; TTL per key |
| Amazon Linux 2023 | Ubuntu, CentOS | AWS-optimized; dnf; free security patches |
| gunicorn | uwsgi, uvicorn | Flask-native; simple configuration |
| gp3 over gp2 | gp2 | Same price, better baseline IOPS |
| NAT per AZ | Single NAT | HA + avoid cross-AZ data transfer cost |
