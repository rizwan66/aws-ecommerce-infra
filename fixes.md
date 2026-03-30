# Deployment Fixes & Issue Log

All issues encountered during the initial AWS deployment of the ecommerce infrastructure, with root cause analysis and the fix applied.

---

## 1. HCL Syntax Error — Semicolon in Variable Block

**File:** `terraform/modules/rds/variables.tf`

**Cause:** The `db_password` variable used a single-line block with a semicolon to separate multiple attributes, which is invalid HCL syntax. Semicolons are not supported as attribute separators in Terraform.

**Broken:**
```hcl
variable "db_password" { type = string; sensitive = true }
```

**Fix:**
```hcl
variable "db_password" {
  type      = string
  sensitive = true
}
```

---

## 2. Missing `artifacts_bucket_name` Variable Threading

**Files:** `terraform/modules/ec2/variables.tf`, `terraform/modules/ec2/main.tf`, `terraform/main.tf`

**Cause:** The `user_data.sh.tpl` template referenced `${artifacts_bucket_name}` for the S3 sync command, but this variable was never declared in the EC2 module or passed from the root module. This would cause `terraform validate` to fail.

**Fix:**
- Added `variable "artifacts_bucket_name"` to `modules/ec2/variables.tf`
- Added `artifacts_bucket_name = var.artifacts_bucket_name` to the `templatefile()` call in `modules/ec2/main.tf`
- Created `terraform/artifacts.tf` with the S3 artifacts bucket resource
- Added `artifacts_bucket_name = aws_s3_bucket.artifacts.bucket` to the `module "ec2"` block in `main.tf`

---

## 3. S3 IAM Wildcard Mismatch

**File:** `terraform/modules/iam/main.tf`

**Cause:** The EC2 IAM policy granted S3 access to `arn:aws:s3:::*-artifacts` but the artifacts bucket is named `*-artifacts-{account_id}` (account-scoped for uniqueness). The wildcard didn't match.

**Fix:**
```hcl
# Before
"arn:aws:s3:::*-artifacts",
"arn:aws:s3:::*-artifacts/*"

# After
"arn:aws:s3:::*-artifacts-*",
"arn:aws:s3:::*-artifacts-*/*"
```

---

## 4. Terraform Template Dollar-Sign Conflict

**File:** `terraform/modules/ec2/user_data.sh.tpl`

**Cause:** The Jinja2 template expression `${{ "%.2f" | format(p.price) }}` in the embedded HTML starts with `${`, which Terraform's `templatefile()` function interprets as a template variable interpolation. This caused a parse error: `Bitwise operators are not supported`.

**Fix:** Escape the leading `$` with `$$` so Terraform passes it through as a literal `$`:
```html
<!-- Before -->
<div class="price">${{ "%.2f" | format(p.price) }}</div>

<!-- After -->
<div class="price">$${{ "%.2f" | format(p.price) }}</div>
```

---

## 5. AWS Config Recorder Account Limit

**File:** `terraform/modules/monitoring/main.tf`

**Cause:** AWS allows only one Config configuration recorder per account. The account already had an existing recorder from a prior setup, so Terraform failed with `MaxNumberOfConfigurationRecordersExceededException`.

**Fix:** Removed the `aws_config_configuration_recorder`, `aws_config_delivery_channel`, `aws_config_configuration_recorder_status`, and three `aws_config_config_rule` resources from the monitoring module. Replaced with a comment directing management via the AWS Console or `terraform import`.

---

## 6. Duplicate Security Group Ingress Rule

**File:** `terraform/modules/security/main.tf`

**Cause:** The `app` security group had two identical ingress rules both allowing port 8080 from the ALB security group — one labelled "HTTP from ALB only" and another "Health check from ALB". AWS rejected the second rule with `InvalidParameterValue: The same permission must not appear multiple times`.

**Fix:** Removed the duplicate rule, keeping a single ingress rule covering both HTTP traffic and health checks:
```hcl
ingress {
  description     = "HTTP and health check from ALB only"
  from_port       = 8080
  to_port         = 8080
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

---

## 7. Non-ASCII Characters in Security Group Descriptions

**File:** `terraform/modules/security/main.tf`

**Cause:** The RDS and ElastiCache security group descriptions used an em-dash (`—`, Unicode U+2014) which is outside the ASCII range. AWS EC2 API rejects security group descriptions containing non-ASCII characters with `InvalidParameterValue`.

**Fix:** Replaced em-dashes with standard hyphens:
```
# Before
"Security group for RDS — app tier access only"
"Security group for ElastiCache — app tier access only"

# After
"Security group for RDS - app tier access only"
"Security group for ElastiCache - app tier access only"
```

---

## 8. RDS Free-Tier Restrictions

**File:** `terraform/modules/rds/main.tf`, `terraform/variables.tf`

**Cause:** The account is on AWS Free Tier, which imposes restrictions on RDS:
- Maximum backup retention period is 0 (free tier doesn't support automated backups)
- Multi-AZ is not available on free tier
- `db.t3.medium` is not eligible; free tier requires `db.t3.micro`
- Enhanced Monitoring (`monitoring_interval > 0`) and Performance Insights are not supported on `db.t3.micro`

**Fix:** Updated RDS configuration to free-tier compatible settings:
```hcl
multi_az                = false
deletion_protection     = false
skip_final_snapshot     = true
backup_retention_period = 0
monitoring_interval     = 0
performance_insights_enabled = false
instance_class (default) = "db.t3.micro"
```

---

## 9. CloudWatch Dashboard Missing `region` Field

**File:** `terraform/modules/monitoring/main.tf`

**Cause:** Each CloudWatch Dashboard widget requires a `region` field in its `properties` block. Without it, the CloudWatch API returns a validation error: `Should have required property 'region'` for every widget. The dashboard body had 24 validation errors total.

**Fix:** Added `region = data.aws_region.current.name` to all 8 widget `properties` blocks and added a `data "aws_region" "current" {}` data source to the module.

---

## 10. ALB ARN Suffixes Not Passed to EC2 Module

**File:** `terraform/main.tf`

**Cause:** The `module "ec2"` block was missing `alb_arn_suffix` and `tg_arn_suffix` arguments. The EC2 module's request-count scaling policy needs these values to configure the `ALBRequestCountPerTarget` metric. Without them, the values defaulted to `""` and Terraform would attempt to create a scaling policy with `resource_label = "/"` which AWS rejects as an invalid resource label.

**Fix:**
- Added `alb_arn_suffix = module.alb.alb_arn_suffix` and `tg_arn_suffix = module.alb.tg_arn_suffix` to the `module "ec2"` block
- Added a `count` guard to the request-count scaling policy so it's only created when both suffixes are non-empty:
```hcl
resource "aws_autoscaling_policy" "request_count" {
  count = var.alb_arn_suffix != "" && var.tg_arn_suffix != "" ? 1 : 0
  ...
}
```

---

## 11. Password Special Characters Breaking Bash Heredoc

**File:** `terraform/modules/ec2/user_data.sh.tpl`, `terraform/main.tf`

**Cause:** The DB password generated by `random_password` could contain `$` characters. When writing `config.py` using an unquoted heredoc (`<< EOF`), bash expands `$DB_PASSWORD` but if the password itself contains `$`, the interpolated value gets further expanded as a shell variable (e.g., `$abc` in the password becomes empty string). This silently corrupts the password written to `config.py`, causing database connection failures.

**Fix (two-part):**
1. Removed `$` from `override_special` in `random_password` to prevent generation of passwords with dollar signs:
```hcl
override_special = "!#%&*()-_=+[]{}<>:?"  # removed $
```
2. Added Python `repr()` wrapping to safely escape any remaining special characters in the password when writing `config.py`:
```bash
DB_PASS_REPR=$(python3 -c "import sys; print(repr(sys.stdin.readline().rstrip('\n')))" <<< "$DB_PASSWORD")
cat > /opt/ecommerce/config.py << EOF
...
DB_PASS = $DB_PASS_REPR
...
EOF
```

---

## 12. Gunicorn Not Found at `/usr/bin/gunicorn`

**File:** `terraform/modules/ec2/user_data.sh.tpl`

**Cause:** The systemd service unit hardcoded `ExecStart=/usr/bin/gunicorn`, but `pip3 install` on Amazon Linux 2023 installs scripts to `/usr/local/bin/`, not `/usr/bin/`. The service failed to start with `exec format error` or `No such file or directory`, causing all ALB health checks to fail.

**Fix:** Changed the `ExecStart` to use Python's `-m` flag, which always resolves gunicorn through the same Python that pip installed it into:
```
# Before
ExecStart=/usr/bin/gunicorn --workers 4 --bind 0.0.0.0:8080 --timeout 30 app:app

# After
ExecStart=/usr/bin/python3 -m gunicorn --workers 4 --bind 0.0.0.0:8080 --timeout 30 app:app
```

---

## 13. ALB Port 80 Redirecting to HTTPS (No Certificate)

**File:** `terraform/modules/alb/main.tf`

**Cause:** The port 80 listener was configured with a `redirect` action pointing to `HTTPS:443`. No ACM certificate was provisioned (requires a registered domain), so the HTTPS listener didn't exist. All HTTP requests received a `301 Moved Permanently` response to an unreachable HTTPS endpoint, making the app inaccessible via the ALB DNS name.

The port 8080 "temporary HTTP forward" listener existed but the ALB security group only allowed inbound traffic on ports 80 and 443 — not 8080.

**Fix:** Changed the port 80 listener from a redirect to a direct forward to the target group:
```hcl
default_action {
  type             = "forward"
  target_group_arn = aws_lb_target_group.app.arn
}
```
A comment was added noting that the HTTPS listener should be enabled once an ACM certificate and domain are configured.

---

## 14. CloudWatch Log Collection — File Path vs Journald

**File:** `terraform/modules/ec2/user_data.sh.tpl`

**Cause:** The CloudWatch agent was configured to collect logs from `/var/log/ecommerce/*.log`, but gunicorn running under systemd writes to journald (stdout/stderr captured by `StandardOutput=journal`). No log files are ever created at that path, so the agent collected nothing.

**Fix:** Switched the CloudWatch agent config from `files` to `journald` collection, filtered by the `SyslogIdentifier=ecommerce` set in the systemd unit:
```json
"logs_collected": {
  "journald": {
    "collect_list": [{
      "log_group_name":  "/aws/ec2/ecommerce-prod/app",
      "log_stream_name": "{instance_id}",
      "filters": [{"type": "include", "expression": "SYSLOG_IDENTIFIER=ecommerce"}]
    }]
  }
}
```

---

## Summary

| # | Issue | Component | Severity |
|---|-------|-----------|----------|
| 1 | HCL semicolon syntax | RDS variables | Blocker (validate fails) |
| 2 | Missing variable threading | EC2 / root module | Blocker (validate fails) |
| 3 | IAM S3 wildcard mismatch | IAM | High (S3 access denied) |
| 4 | Terraform template `${` conflict | EC2 user_data | Blocker (validate fails) |
| 5 | AWS Config recorder limit | Monitoring | Blocker (apply fails) |
| 6 | Duplicate SG ingress rule | Security | Blocker (apply fails) |
| 7 | Non-ASCII in SG description | Security | Blocker (apply fails) |
| 8 | RDS free-tier restrictions | RDS | Blocker (apply fails) |
| 9 | Dashboard missing `region` | Monitoring | Blocker (apply fails) |
| 10 | ALB ARN suffixes not passed | EC2 / root module | High (scaling fails) |
| 11 | Password `$` in heredoc | EC2 user_data | High (DB auth fails) |
| 12 | Gunicorn path wrong | EC2 user_data | Blocker (service fails) |
| 13 | ALB HTTP→HTTPS redirect, no cert | ALB | Blocker (unreachable) |
| 14 | Wrong log collection method | EC2 user_data | Medium (no logs) |
