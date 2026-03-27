#!/bin/bash
set -euxo pipefail

# ─── System setup ─────────────────────────────────────────────────────────────
dnf update -y
dnf install -y python3 python3-pip git awscli jq

# ─── Fetch DB password from Secrets Manager ───────────────────────────────────
DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${db_secret_arn}" \
  --region "${aws_region}" \
  --query SecretString \
  --output text)

# ─── Get instance metadata (IMDSv2) ──────────────────────────────────────────
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# ─── Install app ──────────────────────────────────────────────────────────────
mkdir -p /opt/ecommerce
cat > /opt/ecommerce/requirements.txt << 'EOF'
flask==3.0.3
gunicorn==23.0.0
psycopg2-binary==2.9.9
redis==5.0.8
boto3==1.35.0
EOF

pip3 install -r /opt/ecommerce/requirements.txt

# Copy app files (in real deployment use S3/CodeDeploy)
aws s3 cp s3://${project_name}-${environment}-artifacts/app/ /opt/ecommerce/ --recursive || true

cat > /opt/ecommerce/config.py << EOF
INSTANCE_ID = "$INSTANCE_ID"
AZ = "$AZ"
ENVIRONMENT = "${environment}"
DB_HOST = "${db_endpoint}"
DB_NAME = "${project_name}db"
DB_USER = "dbadmin"
DB_PASS = "$DB_PASSWORD"
REDIS_HOST = "${redis_endpoint}"
REDIS_PORT = 6379
EOF

# ─── Systemd service ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/ecommerce.service << 'EOF'
[Unit]
Description=Ecommerce App
After=network.target

[Service]
User=nobody
WorkingDirectory=/opt/ecommerce
ExecStart=/usr/bin/gunicorn --workers 4 --bind 0.0.0.0:8080 app:app
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=ecommerce

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ecommerce
systemctl start ecommerce

# ─── CloudWatch agent ─────────────────────────────────────────────────────────
dnf install -y amazon-cloudwatch-agent

cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
  "metrics": {
    "namespace": "${project_name}/${environment}",
    "metrics_collected": {
      "cpu": { "measurement": ["cpu_usage_active"], "metrics_collection_interval": 60 },
      "mem": { "measurement": ["mem_used_percent"], "metrics_collection_interval": 60 },
      "disk": { "measurement": ["disk_used_percent"], "metrics_collection_interval": 60 }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/ecommerce/*.log",
            "log_group_name": "/aws/ec2/${project_name}/${environment}/app",
            "log_stream_name": "{instance_id}"
          }
        ]
      }
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config \
  -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json \
  -s
