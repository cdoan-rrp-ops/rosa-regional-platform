#!/bin/bash
set -euo pipefail

# =============================================================================
# Bootstrap Central AWS Account
# =============================================================================
# This script bootstraps the central AWS account with:
# 1. Terraform state infrastructure (S3 bucket with lockfile-based locking)
# 2. Regional cluster pipeline infrastructure
# 3. Management cluster pipeline infrastructure
#
# Prerequisites:
# - AWS CLI configured with central account credentials
# - Terraform >= 1.14.3 installed
# - GitHub repository set up
#
# Usage:
#   GITHUB_REPOSITORY=owner/repo GITHUB_BRANCH=main ./bootstrap-central-account.sh
#
#   Or with command-line arguments:
#   ./bootstrap-central-account.sh owner/repo main staging
# =============================================================================

# Show usage
show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [GITHUB_REPOSITORY] [GITHUB_BRANCH] [ENVIRONMENT]

Bootstrap the central AWS account with pipeline infrastructure.

ARGUMENTS:
    GITHUB_REPOSITORY    GitHub repository in owner/name format (default: 'openshift-online/rosa-regional-platform')
    GITHUB_BRANCH        Branch name (default: 'main')
    ENVIRONMENT          Environment to monitor (e.g., integration, staging, production) (default: 'staging')

OPTIONS:
    -h, --help          Show this help message

ENVIRONMENT VARIABLES:
    GITHUB_REPOSITORY   GitHub repository in owner/name format (e.g., 'theautoroboto/rosa-regional-platform')
    GITHUB_BRANCH       Git branch to track (default: main)
    TARGET_ENVIRONMENT  Environment to monitor (default: staging)
    AWS_PROFILE         AWS CLI profile to use

EXAMPLES:
    # With environment variables (recommended)
    GITHUB_REPOSITORY=theautoroboto/rosa-regional-platform GITHUB_BRANCH=bugfix-environment TARGET_ENVIRONMENT=brian $0

    # With command-line arguments
    $0 custom-org/rosa-regional-platform feature-branch staging

    # Using defaults (openshift-online/rosa-regional-platform, main, staging)
    $0
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            # First positional argument found, stop parsing flags
            break
            ;;
    esac
done

# Determine repo root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "🚀 ROSA Regional Platform - Central Account Bootstrap"
echo "======================================================"
echo ""
echo "Repository Root: $REPO_ROOT"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo "❌ Error: AWS CLI not found. Please install AWS CLI."
    exit 1
fi

if ! command -v terraform &> /dev/null; then
    echo "❌ Error: Terraform not found. Please install Terraform >= 1.14.3"
    exit 1
fi

# Get current AWS identity (capture once to avoid duplicate calls)
echo "Checking AWS credentials..."
if ! AWS_IDENTITY=$(aws sts get-caller-identity --no-cli-pager 2>&1); then
    echo "❌ Error: Failed to authenticate with AWS"
    echo "$AWS_IDENTITY"
    exit 1
fi

ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')

if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "❌ Error: Invalid AWS account ID: '$ACCOUNT_ID'"
    exit 1
fi

REGION=$(aws configure get region 2>/dev/null)
REGION=${REGION:-us-east-1}

echo "✅ Authenticated as:"
echo "$AWS_IDENTITY"
echo ""

# Parse command-line arguments or use environment variables (no interactive prompts)
if [ $# -ge 1 ]; then
    # Command-line arguments provided
    GITHUB_REPOSITORY="$1"
    GITHUB_BRANCH="${2:-main}"
    TARGET_ENVIRONMENT="${3:-}"
fi

# Set defaults for optional parameters
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-openshift-online/rosa-regional-platform}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"
TARGET_ENVIRONMENT="${TARGET_ENVIRONMENT:-staging}"

# Validate repository format (must be owner/name)
if [[ ! "$GITHUB_REPOSITORY" =~ ^[^/]+/[^/]+$ ]]; then
    echo "❌ Error: GITHUB_REPOSITORY must be in 'owner/name' format"
    echo "   Example: theautoroboto/rosa-regional-platform"
    exit 1
fi

echo ""
echo "Configuration:"
echo "  Central Account ID: $ACCOUNT_ID"
echo "  AWS Region:         $REGION"
echo "  GitHub Repo:        $GITHUB_REPOSITORY"
echo "  GitHub Branch:      $GITHUB_BRANCH"
echo "  Target Environment: $TARGET_ENVIRONMENT"
echo ""
echo "✅ Proceeding with bootstrap..."

echo ""
echo "==================================================="
echo "Step 1: Creating Terraform State Infrastructure"
echo "==================================================="

# Create state bucket (uses lockfile-based locking)
STATE_BUCKET="terraform-state-${ACCOUNT_ID}"

"${REPO_ROOT}/scripts/bootstrap-state.sh" "$REGION"

echo ""

echo "==================================================="
echo "Step 2: Deploying Pipeline Infrastructure"
echo "==================================================="

cd "${REPO_ROOT}/terraform/config/bootstrap-pipeline"

# Initialize Terraform
echo "Initializing Terraform..."
terraform init -reconfigure \
    -backend-config="bucket=${STATE_BUCKET}" \
    -backend-config="key=bootstrap-pipeline/terraform.tfstate" \
    -backend-config="region=${REGION}" \
    -backend-config="use_lockfile=true"

# Create tfvars file
cat > terraform.tfvars <<EOF
github_repository = "${GITHUB_REPOSITORY}"
github_branch     = "${GITHUB_BRANCH}"
region            = "${REGION}"
environment       = "${TARGET_ENVIRONMENT}"
EOF

echo "Terraform configuration created:"
cat terraform.tfvars
echo ""

# Run terraform plan
echo "Running Terraform plan..."
terraform plan -var-file=terraform.tfvars -out=tfplan

echo ""
echo "✅ Applying Terraform configuration..."
terraform apply tfplan

echo ""
echo "==================================================="
echo "✅ Bootstrap Complete!"
echo "==================================================="
echo ""
echo "🔗 GitHub Connection Authorization:"
echo "   1. Open AWS Console: https://console.aws.amazon.com/codesuite/settings/connections"
echo "   2. Find connections in PENDING state"
echo "   3. Click 'Update pending connection' and authorize with GitHub"
echo ""
echo "To deploy clusters, add region deployments to config.yaml and run scripts/render.py."
echo "Generated files will appear under deploy/<env>/<name>/."
echo ""

cd "${REPO_ROOT}"
