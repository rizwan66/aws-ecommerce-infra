#!/usr/bin/env bash
# destroy.sh — Full teardown for aws-ecommerce-infra
#
# What this script does (in order):
#   1. Pre-flight: verify dependencies and AWS auth
#   2. Empty all S3 buckets managed by this project (required before destroy)
#   3. Disable RDS deletion protection (required before destroy in prod)
#   4. Run terraform destroy on the full stack
#   5. Optionally: delete the Terraform backend bucket + DynamoDB lock table
#
# Usage:
#   ./scripts/destroy.sh [OPTIONS]
#
# Options:
#   --region REGION         AWS region (default: us-east-1)
#   --env ENV               Environment: dev|staging|prod (default: prod)
#   --alert-email EMAIL     Alert email used during apply (default: alerts@example.com)
#   --delete-backend        Also delete S3 state bucket + DynamoDB lock table (IRREVERSIBLE)
#   --auto-approve          Skip all confirmation prompts (use in CI only)
#   --dry-run               Show what would be destroyed without doing it
#
# Examples:
#   ./scripts/destroy.sh --env dev --auto-approve
#   ./scripts/destroy.sh --env prod --delete-backend
#   ./scripts/destroy.sh --dry-run

set -euo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
REGION="us-east-1"
ENVIRONMENT="prod"
ALERT_EMAIL="alerts@example.com"
DELETE_BACKEND=false
AUTO_APPROVE=false
DRY_RUN=false
PROJECT_NAME="ecommerce"
STATE_BUCKET="rizwan66-terraform-state"
STATE_KEY="aws-ecommerce/terraform.tfstate"
LOCK_TABLE="rizwan66-terraform-locks"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$(dirname "$SCRIPT_DIR")/terraform"

# ─── Parse arguments ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)        REGION="$2";        shift 2 ;;
    --env)           ENVIRONMENT="$2";   shift 2 ;;
    --alert-email)   ALERT_EMAIL="$2";   shift 2 ;;
    --delete-backend) DELETE_BACKEND=true; shift ;;
    --auto-approve)  AUTO_APPROVE=true;  shift ;;
    --dry-run)       DRY_RUN=true;       shift ;;
    *)
      echo -e "${RED}Unknown option: $1${RESET}"
      echo "Usage: $0 [--region REGION] [--env ENV] [--alert-email EMAIL] [--delete-backend] [--auto-approve] [--dry-run]"
      exit 1
      ;;
  esac
done

# ─── Helpers ──────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}${CYAN}══════════════════════════════════════════${RESET}"; }

confirm() {
  if $AUTO_APPROVE; then return 0; fi
  local prompt="$1"
  echo -e "${YELLOW}${prompt}${RESET}"
  read -r -p "  Type 'yes' to continue, anything else to abort: " answer
  if [[ "$answer" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
}

dry_run_check() {
  if $DRY_RUN; then
    warn "[DRY RUN] Would execute: $*"
    return 1  # caller should skip actual execution
  fi
  return 0
}

# ─── Step 0: Banner ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${RED}╔════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${RED}║    AWS ECOMMERCE INFRA — FULL TEARDOWN     ║${RESET}"
echo -e "${BOLD}${RED}╚════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Region      : ${BOLD}${REGION}${RESET}"
echo -e "  Environment : ${BOLD}${ENVIRONMENT}${RESET}"
echo -e "  Project     : ${BOLD}${PROJECT_NAME}${RESET}"
echo -e "  State Bucket: ${BOLD}${STATE_BUCKET}${RESET}"
echo -e "  Del Backend : ${BOLD}${DELETE_BACKEND}${RESET}"
echo -e "  Auto Approve: ${BOLD}${AUTO_APPROVE}${RESET}"
echo -e "  Dry Run     : ${BOLD}${DRY_RUN}${RESET}"
echo ""

if $DRY_RUN; then
  warn "DRY RUN MODE — no changes will be made."
fi

# ─── Step 1: Pre-flight checks ────────────────────────────────────────────────
step "Step 1: Pre-flight Checks"

# Check required tools
for tool in aws terraform jq; do
  if ! command -v "$tool" &>/dev/null; then
    error "Required tool not found: $tool"
    exit 1
  fi
  success "$tool is available"
done

# Check AWS auth
info "Verifying AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
  error "AWS credentials not configured or expired. Run 'aws configure' or refresh your SSO session."
  exit 1
}
CALLER=$(aws sts get-caller-identity --query 'Arn' --output text)
success "Authenticated as: ${CALLER}"
success "Account ID: ${ACCOUNT_ID}"

# Warn loudly if targeting prod
if [[ "$ENVIRONMENT" == "prod" ]]; then
  echo ""
  echo -e "${RED}${BOLD}  ██████╗ ██████╗  ██████╗ ██████╗ ${RESET}"
  echo -e "${RED}${BOLD}  ██╔══██╗██╔══██╗██╔═══██╗██╔══██╗${RESET}"
  echo -e "${RED}${BOLD}  ██████╔╝██████╔╝██║   ██║██║  ██║${RESET}"
  echo -e "${RED}${BOLD}  ██╔═══╝ ██╔══██╗██║   ██║██║  ██║${RESET}"
  echo -e "${RED}${BOLD}  ██║     ██║  ██║╚██████╔╝██████╔╝${RESET}"
  echo -e "${RED}${BOLD}  ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ${RESET}"
  echo ""
  warn "You are about to DESTROY PRODUCTION infrastructure."
  warn "This will delete: VPC, EC2 instances, RDS database, ElastiCache,"
  warn "  ALB, security groups, IAM roles, CloudWatch alarms, and all data."
  warn "This action is IRREVERSIBLE."
  echo ""
  confirm "Are you SURE you want to destroy production infrastructure?"
fi

# ─── Step 2: Empty S3 buckets ─────────────────────────────────────────────────
# Terraform cannot delete non-empty S3 buckets. Find and empty all project buckets.
step "Step 2: Empty Project S3 Buckets"
info "Searching for S3 buckets tagged Project=${PROJECT_NAME}..."

BUCKETS=$(aws s3api list-buckets \
  --query "Buckets[*].Name" \
  --output text 2>/dev/null | tr '\t' '\n' | grep -E "${PROJECT_NAME}|rizwan66" || true)

if [[ -z "$BUCKETS" ]]; then
  info "No matching S3 buckets found (may not be deployed yet)."
else
  for BUCKET in $BUCKETS; do
    # Skip the state bucket (handled separately)
    if [[ "$BUCKET" == "$STATE_BUCKET" ]]; then
      info "Skipping state bucket: $BUCKET (handled in Step 5)"
      continue
    fi

    info "Processing bucket: s3://${BUCKET}"

    if dry_run_check "Empty + delete versioned objects in s3://${BUCKET}"; then
      # Delete all versioned objects (handles versioned buckets)
      info "  Removing all object versions..."
      aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null | \
        jq -c 'select(.Objects != null) | {Objects: .Objects, Quiet: true}' | \
        while read -r batch; do
          [[ -z "$batch" || "$batch" == "null" ]] && continue
          aws s3api delete-objects --bucket "$BUCKET" --delete "$batch" > /dev/null
        done

      # Delete all delete markers
      info "  Removing delete markers..."
      aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
        --output json 2>/dev/null | \
        jq -c 'select(.Objects != null) | {Objects: .Objects, Quiet: true}' | \
        while read -r batch; do
          [[ -z "$batch" || "$batch" == "null" ]] && continue
          aws s3api delete-objects --bucket "$BUCKET" --delete "$batch" > /dev/null
        done

      # Remove remaining non-versioned objects
      aws s3 rm "s3://${BUCKET}" --recursive --quiet || true

      success "Emptied: s3://${BUCKET}"
    fi
  done
fi

# ─── Step 3: Disable RDS deletion protection ──────────────────────────────────
step "Step 3: Disable RDS Deletion Protection"
NAME_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}"
RDS_ID="${NAME_PREFIX}-db"

info "Checking RDS instance: ${RDS_ID}"
RDS_STATUS=$(aws rds describe-db-instances \
  --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].DBInstanceStatus' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "NOT_FOUND")

if [[ "$RDS_STATUS" == "NOT_FOUND" || "$RDS_STATUS" == "None" ]]; then
  info "RDS instance ${RDS_ID} not found — skipping."
else
  DELETION_PROTECTION=$(aws rds describe-db-instances \
    --db-instance-identifier "$RDS_ID" \
    --query 'DBInstances[0].DeletionProtection' \
    --output text \
    --region "$REGION")

  if [[ "$DELETION_PROTECTION" == "True" ]]; then
    info "Disabling deletion protection on ${RDS_ID}..."
    if dry_run_check "aws rds modify-db-instance --db-instance-identifier ${RDS_ID} --no-deletion-protection"; then
      aws rds modify-db-instance \
        --db-instance-identifier "$RDS_ID" \
        --no-deletion-protection \
        --apply-immediately \
        --region "$REGION" > /dev/null
      success "Deletion protection disabled on ${RDS_ID}"
    fi
  else
    success "Deletion protection already disabled on ${RDS_ID}"
  fi
fi

# ─── Step 4: Terraform Destroy ────────────────────────────────────────────────
step "Step 4: Terraform Destroy"

info "Changing directory to: ${TF_DIR}"
cd "$TF_DIR"

info "Running terraform init (reconnect to remote state)..."
if dry_run_check "terraform init"; then
  terraform init \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=${STATE_KEY}" \
    -backend-config="region=${REGION}" \
    -backend-config="dynamodb_table=${LOCK_TABLE}" \
    -reconfigure \
    -no-color 2>&1 | tail -5
fi

info "Running terraform plan -destroy to preview what will be removed..."
if dry_run_check "terraform plan -destroy"; then
  terraform plan \
    -destroy \
    -var="environment=${ENVIRONMENT}" \
    -var="alert_email=${ALERT_EMAIL}" \
    -var="aws_region=${REGION}" \
    -no-color \
    -out=destroy.tfplan 2>&1 | tail -20
fi

if ! $DRY_RUN; then
  confirm "Review the destroy plan above. Proceed with terraform destroy?"
fi

info "Running terraform destroy..."
if dry_run_check "terraform destroy"; then
  TF_DESTROY_ARGS=(
    -var="environment=${ENVIRONMENT}"
    -var="alert_email=${ALERT_EMAIL}"
    -var="aws_region=${REGION}"
  )
  if $AUTO_APPROVE; then
    TF_DESTROY_ARGS+=(-auto-approve)
  fi

  terraform destroy "${TF_DESTROY_ARGS[@]}" || {
    error "terraform destroy failed. Some resources may still exist."
    warn "Check the AWS Console and manually delete remaining resources."
    warn "Then run: terraform state list  to see what's left in state."
    exit 1
  }

  # Clean up the local plan file
  rm -f destroy.tfplan

  success "terraform destroy completed successfully"
fi

# ─── Step 5: Clean up remaining resources not managed by Terraform ────────────
step "Step 5: Clean Up Non-Terraform Resources"

# ─── EC2 Key Pairs (if any were created manually) ─────────────────────────────
info "Checking for project key pairs..."
KEY_PAIRS=$(aws ec2 describe-key-pairs \
  --filters "Name=tag:Project,Values=${PROJECT_NAME}" \
  --query 'KeyPairs[*].KeyName' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$KEY_PAIRS" && "$KEY_PAIRS" != "None" ]]; then
  for KP in $KEY_PAIRS; do
    info "Deleting key pair: ${KP}"
    if dry_run_check "aws ec2 delete-key-pair --key-name ${KP}"; then
      aws ec2 delete-key-pair --key-name "$KP" --region "$REGION"
      success "Deleted key pair: ${KP}"
    fi
  done
else
  info "No key pairs to clean up."
fi

# ─── CloudWatch Log Groups ────────────────────────────────────────────────────
info "Checking for CloudWatch log groups..."
LOG_GROUPS=$(aws logs describe-log-groups \
  --log-group-name-prefix "/aws/ec2/${PROJECT_NAME}" \
  --query 'logGroups[*].logGroupName' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

LOG_GROUPS_VPC=$(aws logs describe-log-groups \
  --log-group-name-prefix "/aws/vpc/${PROJECT_NAME}" \
  --query 'logGroups[*].logGroupName' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "")

for LG in $LOG_GROUPS $LOG_GROUPS_VPC; do
  [[ -z "$LG" || "$LG" == "None" ]] && continue
  info "Deleting log group: ${LG}"
  if dry_run_check "aws logs delete-log-group --log-group-name ${LG}"; then
    aws logs delete-log-group --log-group-name "$LG" --region "$REGION" || true
    success "Deleted log group: ${LG}"
  fi
done

# ─── ECR Repository (if app images were pushed) ───────────────────────────────
ECR_REPO="${PROJECT_NAME}-app"
info "Checking for ECR repository: ${ECR_REPO}..."
ECR_EXISTS=$(aws ecr describe-repositories \
  --repository-names "$ECR_REPO" \
  --region "$REGION" \
  --query 'repositories[0].repositoryName' \
  --output text 2>/dev/null || echo "NOT_FOUND")

if [[ "$ECR_EXISTS" != "NOT_FOUND" && "$ECR_EXISTS" != "None" ]]; then
  warn "Found ECR repository: ${ECR_REPO}"
  confirm "Delete ECR repository ${ECR_REPO} and ALL images?"
  if dry_run_check "aws ecr delete-repository --repository-name ${ECR_REPO} --force"; then
    aws ecr delete-repository \
      --repository-name "$ECR_REPO" \
      --force \
      --region "$REGION" > /dev/null
    success "Deleted ECR repository: ${ECR_REPO}"
  fi
else
  info "ECR repository ${ECR_REPO} not found — skipping."
fi

# ─── Secrets Manager (recovery window must expire or be overridden) ───────────
info "Checking Secrets Manager secrets..."
SECRET_NAME="${NAME_PREFIX}/db-password"
SECRET_ARN=$(aws secretsmanager list-secrets \
  --filters Key=name,Values="$SECRET_NAME" \
  --query 'SecretList[0].ARN' \
  --output text \
  --region "$REGION" 2>/dev/null || echo "None")

if [[ "$SECRET_ARN" != "None" && -n "$SECRET_ARN" ]]; then
  info "Scheduling secret deletion (7-day recovery window): ${SECRET_NAME}"
  info "To delete immediately use: aws secretsmanager delete-secret --secret-id ${SECRET_ARN} --force-delete-without-recovery"
  if dry_run_check "aws secretsmanager delete-secret"; then
    # Terraform already scheduled deletion; this is a no-op if already done
    aws secretsmanager delete-secret \
      --secret-id "$SECRET_ARN" \
      --recovery-window-in-days 7 \
      --region "$REGION" 2>/dev/null || true
    success "Secret scheduled for deletion: ${SECRET_NAME}"
  fi
else
  info "Secret ${SECRET_NAME} not found (already deleted or never created)."
fi

# ─── Step 6: Optionally delete Terraform backend ──────────────────────────────
step "Step 6: Terraform Backend"

if $DELETE_BACKEND; then
  warn "You requested deletion of the Terraform backend."
  warn "  Bucket  : s3://${STATE_BUCKET}"
  warn "  Table   : ${LOCK_TABLE}"
  warn "This will permanently delete ALL Terraform state history."
  confirm "Delete Terraform backend (state bucket + lock table)?"

  # Empty state bucket first
  info "Emptying state bucket: s3://${STATE_BUCKET}..."
  if dry_run_check "aws s3 rm s3://${STATE_BUCKET} --recursive"; then
    # Delete all versions (versioning is enabled)
    aws s3api list-object-versions \
      --bucket "$STATE_BUCKET" \
      --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null | \
      jq -c 'select(.Objects != null) | {Objects: .Objects, Quiet: true}' | \
      while read -r batch; do
        [[ -z "$batch" || "$batch" == "null" ]] && continue
        aws s3api delete-objects --bucket "$STATE_BUCKET" --delete "$batch" > /dev/null
      done

    aws s3api list-object-versions \
      --bucket "$STATE_BUCKET" \
      --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
      --output json 2>/dev/null | \
      jq -c 'select(.Objects != null) | {Objects: .Objects, Quiet: true}' | \
      while read -r batch; do
        [[ -z "$batch" || "$batch" == "null" ]] && continue
        aws s3api delete-objects --bucket "$STATE_BUCKET" --delete "$batch" > /dev/null
      done

    aws s3 rm "s3://${STATE_BUCKET}" --recursive --quiet || true

    # Delete the bucket
    info "Deleting state bucket..."
    aws s3api delete-bucket --bucket "$STATE_BUCKET" --region "$REGION"
    success "Deleted state bucket: s3://${STATE_BUCKET}"
  fi

  # Delete DynamoDB lock table
  info "Deleting DynamoDB lock table: ${LOCK_TABLE}..."
  if dry_run_check "aws dynamodb delete-table --table-name ${LOCK_TABLE}"; then
    aws dynamodb delete-table \
      --table-name "$LOCK_TABLE" \
      --region "$REGION" > /dev/null 2>&1 || true
    success "Deleted DynamoDB table: ${LOCK_TABLE}"
  fi
else
  info "Backend retained (use --delete-backend to also remove state bucket + lock table)."
fi

# ─── Step 7: Verification ─────────────────────────────────────────────────────
step "Step 7: Verification"

if ! $DRY_RUN; then
  info "Verifying no EC2 instances remain for this project..."
  REMAINING_EC2=$(aws ec2 describe-instances \
    --filters \
      "Name=tag:Project,Values=${PROJECT_NAME}" \
      "Name=instance-state-name,Values=running,stopped,pending,stopping" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

  if [[ -n "$REMAINING_EC2" && "$REMAINING_EC2" != "None" ]]; then
    warn "The following EC2 instances still exist (may be terminating):"
    echo "$REMAINING_EC2"
  else
    success "No EC2 instances found for project ${PROJECT_NAME}"
  fi

  info "Verifying no RDS instances remain..."
  REMAINING_RDS=$(aws rds describe-db-instances \
    --query "DBInstances[?contains(DBInstanceIdentifier,'${PROJECT_NAME}')].DBInstanceIdentifier" \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

  if [[ -n "$REMAINING_RDS" && "$REMAINING_RDS" != "None" ]]; then
    warn "The following RDS instances still exist (may be deleting): ${REMAINING_RDS}"
    info "RDS deletion takes ~5 minutes. Check the AWS Console."
  else
    success "No RDS instances found for project ${PROJECT_NAME}"
  fi

  info "Verifying no ALBs remain..."
  REMAINING_ALB=$(aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(LoadBalancerName,'${PROJECT_NAME}')].LoadBalancerName" \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

  if [[ -n "$REMAINING_ALB" && "$REMAINING_ALB" != "None" ]]; then
    warn "ALBs still exist (may be deleting): ${REMAINING_ALB}"
  else
    success "No ALBs found for project ${PROJECT_NAME}"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║              TEARDOWN COMPLETE             ║${RESET}"
echo -e "${BOLD}${GREEN}╚════════════════════════════════════════════╝${RESET}"
echo ""
if $DRY_RUN; then
  warn "DRY RUN complete — no resources were actually deleted."
  info "Re-run without --dry-run to perform the actual teardown."
else
  success "All Terraform-managed resources have been destroyed."
  success "Non-Terraform resources (log groups, ECR) have been cleaned up."
  if $DELETE_BACKEND; then
    success "Terraform backend (S3 + DynamoDB) has been deleted."
  else
    info "Terraform backend (s3://${STATE_BUCKET}) was retained."
    info "Run with --delete-backend to remove it too."
  fi
  echo ""
  info "Estimated time for final cleanup in AWS Console:"
  info "  RDS instances:     ~5 minutes"
  info "  ElastiCache:       ~5 minutes"
  info "  NAT Gateways:      ~2 minutes"
  info "  VPC:               ~1 minute (after all dependencies deleted)"
fi
echo ""
