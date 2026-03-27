#!/usr/bin/env bash
# drift-detection.sh
# Detect infrastructure drift by comparing Terraform state to live AWS resources.
# Exits 1 if drift is detected; exits 0 if infrastructure matches state.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

echo "==> Initializing Terraform..."
terraform init -reconfigure > /dev/null

echo "==> Running terraform plan (drift check)..."
set +e
terraform plan \
  -var="alert_email=${ALERT_EMAIL:-alerts@example.com}" \
  -detailed-exitcode \
  -out=/dev/null 2>&1
EXIT_CODE=$?
set -e

case $EXIT_CODE in
  0)
    echo ""
    echo "[OK] No drift detected — infrastructure matches Terraform state."
    exit 0
    ;;
  1)
    echo ""
    echo "[ERROR] Terraform plan encountered an error. Check output above."
    exit 1
    ;;
  2)
    echo ""
    echo "[DRIFT DETECTED] Infrastructure has drifted from Terraform state!"
    echo "Run 'terraform apply' to reconcile, or investigate manual changes."
    exit 1
    ;;
esac
