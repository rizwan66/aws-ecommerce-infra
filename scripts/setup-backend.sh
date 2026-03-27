#!/usr/bin/env bash
# setup-backend.sh
# Bootstrap Terraform remote state: creates the S3 bucket and DynamoDB lock table.
# Run ONCE before the first `terraform init`.
#
# Usage:  ./scripts/setup-backend.sh [REGION]
set -euo pipefail

REGION="${1:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="rizwan66-terraform-state"
TABLE="rizwan66-terraform-locks"

echo "==> Account : $ACCOUNT_ID"
echo "==> Region  : $REGION"
echo "==> Bucket  : $BUCKET"
echo "==> Table   : $TABLE"
echo ""

# ─── S3 bucket ────────────────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "[OK] S3 bucket already exists: $BUCKET"
else
  echo "--> Creating S3 bucket..."
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

echo "--> Enabling versioning..."
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo "--> Enabling server-side encryption..."
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]
  }'

echo "--> Blocking public access..."
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# ─── DynamoDB lock table ───────────────────────────────────────────────────────
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" &>/dev/null; then
  echo "[OK] DynamoDB table already exists: $TABLE"
else
  echo "--> Creating DynamoDB lock table..."
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION"
fi

echo ""
echo "==> Backend bootstrap complete!"
echo "    Run: cd terraform && terraform init"
