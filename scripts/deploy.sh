#!/usr/bin/env bash
# deploy.sh — Bootstrap backend, init, plan, and apply the full stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"

# ─── Defaults ─────────────────────────────────────────────────────────────────
ENVIRONMENT="${ENVIRONMENT:-prod}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
SKIP_BACKEND="${SKIP_BACKEND:-false}"

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ─── Parse flags ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --env)            ENVIRONMENT="$2";   shift 2 ;;
    --region)         AWS_REGION="$2";    shift 2 ;;
    --auto-approve)   AUTO_APPROVE=true;  shift   ;;
    --skip-backend)   SKIP_BACKEND=true;  shift   ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# ─── Pre-flight checks ────────────────────────────────────────────────────────
info "Pre-flight checks..."
for cmd in aws terraform git; do
  command -v "$cmd" &>/dev/null || die "$cmd not found in PATH"
done

aws sts get-caller-identity --query 'Account' --output text &>/dev/null \
  || die "AWS credentials not configured (run: aws configure or set env vars)"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
success "AWS account: $ACCOUNT_ID  region: $AWS_REGION"

# ─── Step 1: Bootstrap backend ────────────────────────────────────────────────
if [[ "$SKIP_BACKEND" == "false" ]]; then
  info "Step 1/5: Bootstrapping Terraform backend..."
  bash "$SCRIPT_DIR/setup-backend.sh" || warn "Backend setup may have already run (continuing)"
  success "Backend ready"
else
  info "Step 1/5: Skipping backend bootstrap (--skip-backend)"
fi

# ─── Step 2: Terraform init ───────────────────────────────────────────────────
info "Step 2/5: terraform init..."
cd "$TF_DIR"
terraform init -input=false
success "init complete"

# ─── Step 3: Terraform validate ───────────────────────────────────────────────
info "Step 3/5: terraform validate..."
terraform validate
success "validate passed"

# ─── Step 4: Terraform plan ───────────────────────────────────────────────────
info "Step 4/5: terraform plan..."
PLAN_ARGS=(
  -var="environment=$ENVIRONMENT"
  -var="aws_region=$AWS_REGION"
  -out=tfplan
  -input=false
)
terraform plan "${PLAN_ARGS[@]}"
success "plan saved to tfplan"

# ─── Step 5: Terraform apply ──────────────────────────────────────────────────
if [[ "$AUTO_APPROVE" == "true" ]]; then
  info "Step 5/5: terraform apply (auto-approved)..."
  terraform apply -input=false tfplan
else
  echo ""
  echo -e "${YELLOW}Review the plan above. Apply to AWS account ${ACCOUNT_ID}?${NC}"
  read -r -p "Type 'yes' to continue: " confirm
  [[ "$confirm" == "yes" ]] || { warn "Aborted."; exit 0; }
  info "Step 5/5: terraform apply..."
  terraform apply -input=false tfplan
fi

success "Deployment complete!"

# ─── Show outputs ─────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  DEPLOYMENT OUTPUTS"
echo "════════════════════════════════════════════════════════"
terraform output

ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null || echo "")
if [[ -n "$ALB_DNS" ]]; then
  echo ""
  info "ALB endpoint: http://$ALB_DNS"
  info "Waiting 90 s for instances to pass health checks..."
  sleep 90
  if curl -sf --max-time 10 "http://$ALB_DNS/health" | python3 -m json.tool 2>/dev/null; then
    success "Application is HEALTHY at http://$ALB_DNS"
  else
    warn "Health check not passing yet — instances may still be warming up."
    warn "Run: curl http://$ALB_DNS/health"
  fi
fi
